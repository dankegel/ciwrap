from buildbot.buildslave import BuildSlave
from buildbot.changes import filter
from buildbot.config import BuilderConfig
from buildbot.process.factory import BuildFactory
from buildbot.schedulers.basic import SingleBranchScheduler
from buildbot.schedulers.forcesched import ForceScheduler, FixedParameter, StringParameter
from buildbot.status import html
from buildbot.status.web import authz, auth
from buildbot.steps.shell import ShellCommand
from buildbot.steps.source.git import Git
from twisted.python import log
import json
import os

from buildbot.changes.gitpoller import GitPoller

class SimpleConfig(dict):
    """A buildbot master which has a web status page, offsets port numbers according to a text file, and reads secrets from a json file."""
    def get_http_port(self):
        return self.__http_port

    def __init__(self,
                 name,
                 homepage,
                 secretsfile="~/myconfig.json",
                 *args, **kwargs):
        dict.__init__(self,*args,**kwargs)

        ####### PORT NUMBERS
        # It's hard to keep port numbers straight for multiple projects,
        # so let's assign each project a slot number,
        # and use 8010 + slotnum for the http port,
        # 9010 + slotnum for the slave port,
        # etc.  bslave.sh duplicates this code.
        thisfile = __file__
        thisfile = thisfile.replace(".pyc", ".py")
        try:
            thisfile = os.readlink(thisfile)
        except:
            pass
        dir = os.path.join(os.path.dirname(thisfile), "..", name)
        print "dir is %s" % dir
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
            pingBuilder = False,
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

        self['title'] = name;
        self['titleURL'] = homepage;

        # the 'buildbotURL' string should point to the location where the buildbot's
        # internal web server (usually the html.WebStatus page) is visible. This
        # typically uses the port number set in the Waterfall 'status' entry, but
        # with an externally-visible host name which the buildbot cannot figure out
        # without some help.

        self['buildbotURL'] = "http://localhost:%d/" % self.get_http_port()

        # For seeing if we've configured a given slave yet.  Easier than searching self['slaves'].
        self._slavehash = {}

        # These will be built up over the course of one or more calls to addSimpleProject
        self['slaves'] = []
        self['change_source'] = []
        self['builders'] = []
        self['schedulers'] = []




    def addSimpleProject(self, name, repourl, slaveconfigfile):
        """Add a project which builds when the source changes or when Force is clicked,
        and gets its list of branches and slaves from the given json file.

        """

        ####### SLAVES
        sf = json.load(open(os.path.expanduser(slaveconfigfile)))
        slaveconfigs = sf["slaves"];
        branchnames = []
        slavenames = []
        operatingsystems = []
        osbranch2slavenames = {}
        for slaveconfig in slaveconfigs:
            sname = slaveconfig["name"].encode('ascii','ignore')
            sbranch = slaveconfig["branch"].encode('ascii','ignore')
            sos = slaveconfig["os"].encode('ascii','ignore')
            if sname not in self._slavehash:
                s = BuildSlave(sname, self.slavepass)
                self['slaves'].append(s)
                self._slavehash[sname] = s
            
	    osbranch = sos+'-'+sbranch
            if osbranch not in osbranch2slavenames:
                osbranch2slavenames[osbranch] = []
            if sname not in osbranch2slavenames[osbranch]:
                osbranch2slavenames[osbranch].append(sname)
            if sbranch not in branchnames:
                branchnames.append(sbranch)
            if sos not in operatingsystems:
                operatingsystems.append(sos)

        ####### CHANGESOURCES
        # It's a git git git git git world
        self['change_source'].append(
            GitPoller(repourl,  branches=branchnames, workdir='gitpoller-workdir-'+name, pollinterval=300))

        ####### BUILDERS
        factory = BuildFactory()
        # check out the source
        factory.addStep(Git(repourl=repourl, mode='full', method='copy'))
        for step in ["install_deps", "configure", "compile", "check", "package", "uninstall_deps"]:
            factory.addStep(ShellCommand(command=["../../buildshim", step], description=step))
        # Give each branch its own builder to make the waterfall easier to read
        for osbranch in osbranch2slavenames:
            self['builders'].append(
                BuilderConfig(name=name+'-'+osbranch,
                  slavenames=osbranch2slavenames[osbranch],
                  factory=factory))

        ####### SCHEDULERS
        for sos in operatingsystems:
            for branch in branchnames:
	        osbranch = sos+'-'+branch
                if osbranch in osbranch2slavenames:
                    buildername = name+'-'+osbranch
                    self['schedulers'].append(
                        SingleBranchScheduler(
                            name=buildername,
                            change_filter=filter.ChangeFilter(branch=branch),
                            treeStableTimer=None,
                            builderNames=[buildername]))
                    self['schedulers'].append(
                        ForceScheduler(
                            name=buildername+"force",
                            builderNames=[buildername],
                            branch=FixedParameter(name="branch", default=branch),
                            # will generate nothing in the form, but revision, repository,
                            # and project are needed by buildbot scheduling system so we
                            # need to pass a value ("")
                            revision=FixedParameter(name="revision", default=""),
                            repository=FixedParameter(name="repository", default=""),
                            project=FixedParameter(name="project", default=""),
                            properties=[
                                StringParameter(name="pull_url",
                                    label="experimental: optional git pull url:<br>",
                                    default="", size=80)
                            ]
                        ))
