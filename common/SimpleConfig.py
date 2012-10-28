from buildbot.status import html
from buildbot.status.web import authz, auth
from buildbot.schedulers.basic import SingleBranchScheduler
from buildbot.schedulers.forcesched import ForceScheduler
from buildbot.changes import filter
from twisted.python import log
import json
import os

class SimpleConfig(dict):
    def get_http_port(self):
        return self.__http_port

    def __init__(self,
                 name,
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

        ####### SCHEDULERS
        # Configure the Schedulers, which react to incoming changes.
        # In this case, just kick off a 'runtests' build
        self['schedulers'] = []
        self['schedulers'].append(
            SingleBranchScheduler(
                name="all",
                change_filter=filter.ChangeFilter(branch='master'),
                treeStableTimer=None,
                builderNames=["runtests"]))
        self['schedulers'].append(
            ForceScheduler(
                name="force",
                builderNames=["runtests"]))

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

