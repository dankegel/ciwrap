from buildbot.buildslave import BuildSlave
from buildbot.changes import filter
from buildbot.config import BuilderConfig
from buildbot.process.factory import BuildFactory
from buildbot.process.properties import WithProperties
from buildbot.schedulers.basic import SingleBranchScheduler
from buildbot.schedulers.forcesched import ForceScheduler, FixedParameter, StringParameter
from buildbot.status import html
from buildbot.status.web import authz, auth
from buildbot.steps.shell import ShellCommand
from twisted.python import log
import json
import os

from buildbot.steps.source.git import Git
from buildbot.changes.gitpoller import GitPoller

from buildbot.steps.source.mercurial import Mercurial
from buildbot.changes.hgpoller import HgPoller

class SimpleConfig(dict):
    """A buildbot master with a web status page and a 'force build' button,
    which reads public configuration from 'master.json'
    and secrets from a different json file (default ~/myconfig.json).

    """

    def __init__(self,
                 name,
                 homepage,
                 secretsfile="~/myconfig.json",
                 *args, **kwargs):
        dict.__init__(self,*args,**kwargs)

        # Find the directory containing this .py file
        thisfile = __file__
        thisfile = thisfile.replace(".pyc", ".py")
        try:
            thisfile = os.readlink(thisfile)
        except:
            pass
        dir = os.path.join(os.path.dirname(thisfile), "..", name)
        print "cwd is %s" % os.getcwd()
        print "dir is %s" % dir

        masterjson = json.load(open(os.path.join(dir, "master.json")))

        ####### PORT NUMBERS
        # It's hard to keep port numbers straight for multiple projects,
        # so let's assign each project a slot number,
        # and use 8010 + slotnum for the http port,
        # 9010 + slotnum for the slave port,
        # etc.  bslave.sh duplicates this code.
        # FIXME: get slot from masterjson
        slot = int(open(os.path.join(dir, "slot.txt")).readline())
        self.__http_port = 8010 + slot
        self['slavePortnum'] = 9010 + slot

        ####### SECRETS
        # Avoid checking secrets into git by keeping them in a json file.
        try:
            s = json.load(open(os.path.expanduser(secretsfile)))
            self.__auth = auth.BasicAuth([(s["webuser"].encode('ascii','ignore'),s["webpass"].encode('ascii','ignore'))])
            # For the moment, all slaves have same password
            self.slavepass = s["slavepass"].encode('ascii','ignore')
        except:
            exit("%s must be a json file containing webuser, webpass, and slavepass; ascii only, no commas in quotes" % secretsfile)

        ####### STATUS TARGETS
        self['status'] = []
        authz_cfg=authz.Authz(
            # change any of these to True to enable; see the manual for more
            # options
            auth=self.__auth,
            gracefulShutdown = False,
            forceBuild = 'auth',
            forceAllBuilds = True,
            pingBuilder = True,
            stopBuild = True,
            stopAllBuilds = False,
            cancelPendingBuild = True,
        )
        self['status'].append(
            html.WebStatus(http_port=self.__http_port, authz=authz_cfg))

        ####### DB URL
        self['db'] = {
            # This specifies what database buildbot uses to store its state.
            # This default is ok for all but the largest installations.
            'db_url' : "sqlite:///state.sqlite",
        }

        ####### PROJECT IDENTITY
        # the 'title' string will appear at the top of this buildbot
        # installation's html.WebStatus home page (linked to the
        # 'titleURL') and is embedded in the title of the waterfall HTML page.

        # FIXME: get name and homepage from masterjson
        self['title'] = name
        self['titleURL'] = homepage

        # the 'buildbotURL' string should point to the location where the buildbot's
        # internal web server (usually the html.WebStatus page) is visible. This
        # typically uses the port number set in the Waterfall 'status' entry, but
        # with an externally-visible host name which the buildbot cannot figure out
        # without some help.

        self['buildbotURL'] = "http://localhost:%d/" % self.__http_port

        ####### SLAVES
        self._os2slaves = {}
        self['slaves'] = []
        slaveconfigs = masterjson["slaves"]
        for slaveconfig in slaveconfigs:
            sname = slaveconfig["name"].encode('ascii','ignore')
            sos = slaveconfig["os"].encode('ascii','ignore')
            # Turn on our 'one build and then exit' feature if user asks for it
            props = { 'oneshot' : False }
            if "oneshot" in slaveconfig:
                oneshot = slaveconfig["oneshot"].encode('ascii','ignore')
                if oneshot == "True":
                    props['oneshot'] = True
                else:
                    exit("oneshot property must be absent or True")
            # Restrict to a single build at a time because our buildshims
            # typically assume they have total control of machine, and use sudo apt-get, etc. with abandon.
            s = BuildSlave(sname, self.slavepass, max_builds=1, properties = props)
            self['slaves'].append(s)
            if sos not in self._os2slaves:
                self._os2slaves[sos] = []
            self._os2slaves[sos].append(sname)

        # These will be built up over the course of one or more calls to addSimpleProject
        self['change_source'] = []
        self['builders'] = []
        self['schedulers'] = []

        # Righty-o, wire 'em all up
        for project in masterjson["projects"]:
            self.addSimpleProject(project)


    def addSimpleProject(self, project):
        """Private.
        Add a project which builds when the source changes or when Force is clicked.

        """
        name = project["name"].encode('ascii','ignore')
        repourl = project["repourl"].encode('ascii','ignore')
        builderconfigs = project["builders"]

        repotype = 'git'
        if "repotype" in project:
            repotype = project["repotype"]

        ####### FACTORIES
        # This fails with git-1.8 and up unless you specify the branch, so use one factory per builder
        # in buildbot-0.8.7 (though a fix was committed later to the 0.8.7 branch)
        # FIXME: use Interpolate("... %(src::branch)s ...") so we can share factories again
        # FIXME: get list of steps from buildshim here
        #factory = BuildFactory()
        #factory.addStep(Git(repourl=repourl, mode='full', method='copy'))
        #for step in ["install_deps", "configure", "compile", "check", "package", "uninstall_deps"]:
        #    factory.addStep(ShellCommand(command=["../../srclink/" + name + "/buildshim", step], description=step))

        ####### BUILDERS AND SCHEDULERS
        # For each builder in config file, see what OS they want to
        # run on, and assign them to suitable slaves.
        # Also create a force scheduler that knows about all the builders.
        branchnames = []
        buildernames = []
        for builderconfig in builderconfigs:
            sbranch = builderconfig["branch"].encode('ascii','ignore')
            if sbranch not in branchnames:
                branchnames.append(sbranch)

            sos = builderconfig["os"].encode('ascii','ignore')
            osbranch = sos+'-'+sbranch
            buildername = name+'-'+osbranch

            factory = BuildFactory()

            # FIXME: move vcs interface into helper function(s)
            if repotype == 'git':
                factory.addStep(Git(repourl=repourl, mode='full', method='copy', branch=sbranch))
                # FIXME: add code to abort if output of 'git branch' doesn't equal sbranch?
                # (But what about try builders that take a git url?)
                factory.addStep(ShellCommand(command=["git", "branch"], description="git branch"))
            elif repotype == 'hg':
                factory.addStep(Mercurial(repourl=repourl, mode="full", method="fresh", branchType="inrepo"))
            else:
                abort("unknown repotype %s" % repotype)

            for step in ["patch", "install_deps", "configure", "compile", "check", "package", "upload", "uninstall_deps"]:
                factory.addStep(ShellCommand(command=["../../srclink/" + name + "/buildshim", step], description=step))

            self['builders'].append(
                BuilderConfig(name=buildername,
                  slavenames=self._os2slaves[sos],
                  factory=factory))

            self['schedulers'].append(
                SingleBranchScheduler(
                    name=buildername,
                    change_filter=filter.ChangeFilter(branch=sbranch),
                    treeStableTimer=None,
                    builderNames=[buildername]))
            buildernames.append(buildername)

        self['schedulers'].append(
            ForceScheduler(
                name=name+"-force",
                builderNames=buildernames,
                branch=FixedParameter(name="branch", default=""),
                revision=FixedParameter(name="revision", default=""),
                repository=FixedParameter(name="repository", default=""),
                project=FixedParameter(name="project", default=""),
                properties=[],
            ))

        ####### CHANGESOURCES
        if repotype == 'git':
            self['change_source'].append(
                GitPoller(repourl, branches=branchnames,
                          workdir='gitpoller-workdir-'+name,
                          pollinterval=300))
        elif repotype == 'hg':
            for branchname in branchnames:
                self['change_source'].append(
                    HgPoller(repourl, branch=branchname,
                          pollInterval=300,
                          workdir='hgpoller-workdir-'+name))
        else:
            abort("unknown repotype %s" % repotype)
