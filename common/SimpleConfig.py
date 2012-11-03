from buildbot.buildslave import BuildSlave
from buildbot.status import html
from buildbot.status.web import authz, auth
from buildbot.schedulers.basic import SingleBranchScheduler
from buildbot.schedulers.forcesched import ForceScheduler
from buildbot.changes import filter
from twisted.python import log
import json
import os

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
            stopBuild = False,
            stopAllBuilds = False,
            cancelPendingBuild = False,
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


    def addSimpleProject(self, name, slavenames, repourl, repobranch="master"):
        """Add a project with one branch and one platform, which builds when
        the source changes or when Force is clicked.

        """

        ####### CHANGESOURCES
        # the 'change_source' setting tells the buildmaster how it should find out
        # about source code changes.  

        from buildbot.changes.gitpoller import GitPoller
        self['change_source'] = []
        self['change_source'].append(
            GitPoller(repourl,  branch=repobranch, workdir='gitpoller-workdir', pollinterval=300))

        ####### BUILDERS

        # The 'builders' list defines the Builders, which tell Buildbot how to perform a build:
        # what steps, and which slaves can execute them.  Note that any particular build will
        # only take place on one slave.

        from buildbot.process.factory import BuildFactory
        from buildbot.steps.source.git import Git
        from buildbot.steps.shell import ShellCommand

        factory = BuildFactory()
        # check out the source
        factory.addStep(Git(repourl=repourl, mode='full', method='copy'))
        for step in ["install_deps", "configure", "compile", "check", "package", "uninstall_deps"]:
            factory.addStep(ShellCommand(command=["../../buildshim", step], description=step))

        from buildbot.config import BuilderConfig

        self['builders'] = []
        self['builders'].append(
            BuilderConfig(name=name,
              slavenames=slavenames,
              factory=factory))

        self['slaves'] = []
        for slavename in slavenames:
            self['slaves'].append(BuildSlave(slavename, self.slavepass))

        ####### SCHEDULERS
        # Configure the Schedulers, which react to incoming changes.
        # In this case, just kick off a 'runtests' build
        self['schedulers'] = []
        self['schedulers'].append(
            SingleBranchScheduler(
                name="all",
                change_filter=filter.ChangeFilter(branch=repobranch),
                treeStableTimer=None,
                builderNames=[name]))
        self['schedulers'].append(
            ForceScheduler(
                name="force",
                builderNames=[name]))
