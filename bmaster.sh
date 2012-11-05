#!/bin/sh
# Copyright Dan Kegel 2012
# See COPYING for details

usage() {
cat << _EOF_
Convenience script for buildbot masters; handy place to hide nasty details and enforce conventions.
Usage:
    sh bmaster.sh install
    sh bmaster.sh [init|check|uninit] PROJECTNAME
    sh bmaster.sh uninstall
_EOF_
}

set -x
set -e

# Where this script lives
SRC=`dirname $0`
# Get an absolute directory (for the case where it's run with 'sh bmaster.sh')
SRC=`cd $SRC; pwd`

# Detect OS
case "`uname -s`" in
Linux)
    case "`lsb_release -ds`" in
    "Ubuntu 10.04"*) _os=ubu1004;;
    "Ubuntu 12.04"*) _os=ubu1204;;
    "Ubuntu 12.10"*) _os=ubu1210;;
    *) abort "unrecognized linux";;
    esac
    ;;
Darwin) abort "don't support mac yet";;
CYGWIN*WOW64) _os=cygwin;;
CYGWIN*)      _os=cygwin;;
*) abort "unrecognized os";;
esac

abort() {
    echo fatal error: $1
    exit 1
}

if test "$LOGNAME" = ""
then
    # Upstart don't set USERNAME or LOGNAME.  id -nu should work on upstart systems.
    # Cygwin sets USERNAME, but not LOGNAME.  Happily, id -nu works on cygwin.
    BUILDUSER=`id -nu`
    BUILDUSERHOME=`eval echo ~$BUILDUSER`
else
    BUILDUSER=$LOGNAME
    BUILDUSERHOME=$HOME
fi

case $_os in
cygwin)
    if test $BUILDUSER = SYSTEM
    then
        echo "Cygwin service, no idea what real user is, hope it's 'buildbot'."
        BUILDUSER=buildbot
        BUILDUSERHOME=`eval echo ~$BUILDUSER`
    fi
    ;;
esac

# Working area; holds all the state of the installed buildbot master instances
TOP=$BUILDUSERHOME/master-state

install_prereqs() {

    if ! git --version
    then
        case $_os in
        ubu1004)  sudo apt-get install git-core;;
        ubu*)   sudo apt-get install git;;
        cygwin) apt-cyg install git;;
        esac
    fi

    if test ! -x "`which unzip 2>/dev/null`"
    then
        case $_os in
        ubu*)   sudo apt-get install unzip;;
        cygwin) apt-cyg install unzip;;
        esac
    fi

    if ! virtualenv --version > /dev/null 2>&1
    then
        case $_os in
        ubu*) sudo apt-get install python-dev python-virtualenv ;;
        cygwin) easy_install pip virtualenv ;;   # README already had you install python
        esac
    fi

    if ! patch --version
    then
        case $_os in
        ubu*)   sudo apt-get install patch;;
        cygwin) apt-cyg install patch;;
        esac
    fi

}

install_buildbot() {
    if test -d "$TOP"
    then
        abort "$TOP already exists"
    fi

    install_prereqs
    (
    # Master
    mkdir -p $TOP
    cd $TOP
    virtualenv --no-site-packages sandbox
    cd $TOP/sandbox
    . bin/activate
    if false
    then
        # Use this if it's up to date enough for you, and you don't plan on making any source changes.
        easy_install buildbot
    elif true
    then
        # Here's how to install from a source tarball.
        wget -c http://buildbot.googlecode.com/files/buildbot-0.8.7.tar.gz
        tar -xzvf buildbot-0.8.7.tar.gz
        cd buildbot-0.8.7
        # Add support for oneshot slaves (for our LXC setup)
        # http://permalink.gmane.org/gmane.comp.python.buildbot.devel/8518
        patch -p2 < $SRC/lxc-local/oneshot.patch
        python setup.py install
        cd ..
    else
        # Here's how to build from git, if you need recent bugfixes
        # BTW rerunning 'pip install -emaster' takes less than a second,
        # and seems to be how buildbot developers test their code
        test -d buildbot-git || git clone https://github.com/buildbot/buildbot.git buildbot-git
        cd buildbot-git
        #git checkout buildbot-0.8.7
        # Add support for oneshot slaves (for our LXC setup)
        # http://permalink.gmane.org/gmane.comp.python.buildbot.devel/8518
        patch -p1 < $SRC/lxc-local/oneshot.patch
        pip install -emaster
        cd ..
    fi

    # Stuff needed by demo's master.cfg
    # FIXME: use local cache
    echo "installing python Path class"
    wget http://pypi.python.org/packages/source/p/path.py/path.py-2.3.zip
    unzip path.py-2.3.zip
    cd path.py-2.3
    python setup.py install
    cd ..
    )
}

sanity_check() {
    dups=`cat */slot.txt | sort | uniq -c | awk '$1 > 1 {print $2}'`
    if test "$dups"
    then
        abort "Slots have duplicate values: $dups"
    fi
}

init_master() {
    sanity_check

    arg="$1"
    (
    cd $TOP/sandbox
    . bin/activate
    orig_mcfg=$SRC/$arg/master.cfg
    orig_jcfg=$SRC/$arg/config.json

    test -f "$orig_mcfg" || abort "no such file $orig_mcfg"
    dir=`dirname $orig_mcfg`
    m=`basename $dir`
    if test -f $VIRTUAL_ENV/$m/master.cfg
    then
        abort "master $m already initialized"
    fi
    # Create buildbot.tac, static html files etc. in given dir
    buildbot create-master -r $VIRTUAL_ENV/$m
    # Symlink to original versions in git of anything we need to override
    ln -sf $orig_mcfg $VIRTUAL_ENV/$m/master.cfg
    ln -sf $orig_jcfg $VIRTUAL_ENV/$m/config.json
    # repetitive, but that's ok
    mkdir -p $VIRTUAL_ENV/common
    ln -sf $SRC/common/* $VIRTUAL_ENV/common
    )
    install_service $arg
}

check_master() {
    arg="$1"
    (
    cd $TOP/sandbox
    . bin/activate
    mcfg=$VIRTUAL_ENV/$arg/master.cfg
    test -f "$mcfg" || abort "no such file $mcfg"
    dir=`dirname $mcfg`
    buildbot checkconfig $dir
    )
}


# Run service in foreground with no extra processes (e.g. subshells) in memory
do_run() {
    arg="$1"
    cd $TOP/sandbox
    . bin/activate

    mcfg=$VIRTUAL_ENV/$arg/master.cfg
    test -f "$mcfg" || abort "no such file $mcfg"
    dir=`dirname $mcfg`
    exec twistd --pidfile $dir/twistd.pid --nodaemon --no_save -y $dir/buildbot.tac
}

uninit_master() {
    uninstall_service $1 || true
    arg="$1"
    (
    cd $TOP/sandbox
    . bin/activate
    mcfg=$VIRTUAL_ENV/$arg/master.cfg
    test -f "$mcfg" || abort "no such file $mcfg"
    dir=`dirname $mcfg`
    buildbot stop $dir
    rm -rf $dir
    )
}

# Add this project's buildmaster to the system service manager.
install_service() {
    arg="$1"
    case $_os in
    ubu*)
    (
        cat  <<_EOF_
description "ciwrap buildbot master startup for $arg"
author "Dan Kegel <dank@kegel.com>"

start on (started network-interface or started network-manager or started networking)
stop on (stopping network-interface or stopping network-manager or stopping networking)
respawn
console log
setuid $BUILDUSER
exec sh $SRC/bmaster.sh run $arg
_EOF_
    ) | sudo tee /etc/init/buildmaster-$arg.conf
    ;;
    cygwin)
        # Must use "run as administrator" to run the cygwin terminal that runs this script!
        cygrunsrv -I buildmaster-$arg --path /bin/sh --args "$SRC/bmaster.sh run $arg"
        ;;
    *) abort "unsupported OS $_os";;
    esac
}

uninstall_service() {
    arg="$1"
    case $_os in
    ubu*)
        sudo rm /etc/init/buildmaster-$arg.conf
        ;;
    cygwin)
        # Must use "run as administrator" to run the cygwin terminal that runs this script!
        cygrunsrv --remove buildmaster-$arg
        ;;
    *) abort "unsupported OS $_os";;
    esac
}

uninstall() {
    rm -rf $TOP
}

case "$1" in
    prereqs)   install_prereqs    ;;   # for testing
    install)   install_buildbot   ;;
    init)      init_master "$2"   ;;
    check)     check_master "$2"  ;;
    run)       do_run "$2"        ;;
    uninit)    uninit_master "$2" ;;
    uninstall) uninstall          ;;
    *) usage; abort "bad arg $1"  ;;
esac
