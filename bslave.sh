#!/bin/sh
# Copyright Dan Kegel 2012
# See COPYING for details

usage() {
cat << _EOF_
Convenience script for buildbot slaves; handy place to hide nasty details and enforce conventions.
Usage:
    sh bslave.sh install
    sh bslave.sh init PROJECTNAME
    sh bslave.sh uninit PROJECTNAME
    sh bslave.sh uninstall
_EOF_
}

set -x
set -e

# Where this script lives
SRC=`dirname $0`
# Get an absolute directory (for the case where it's run with 'sh bslave.sh')
SRC=`cd $SRC; pwd`

# Detect OS
case "`uname -s`" in
Linux)
    case "`lsb_release -ds`" in
    "Ubuntu 10.04"*) _os=ubu1004;;
    "Ubuntu 12.04"*) _os=ubu1204;;
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
    # Upstart jobs don't set traditional variables.
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
        # FIXME: Pick the user that owns $0
        BUILDUSER=buildbot
        BUILDUSERHOME=`eval echo ~$BUILDUSER`
    fi
    ;;
esac

# Working area; holds all the state of the installed buildbot slave instances
TOP=$BUILDUSERHOME/slave-state

# same password for all slaves currently
SLAVE_PASSWD=`awk '/slavepass/ {print $3}' $BUILDUSERHOME/myconfig.json | tr -d '[",]' `

VIRTUAL_ENV=$TOP/$_os

# Hostname of this slave (without domain, assuming this is on a LAN and not the internet)
HOSTNAME=`hostname -s || hostname | tr -d '\015'`
HOSTNAME=`echo $HOSTNAME | tr -d '\015'`
echo HOSTNAME is xx${HOSTNAME}xx

# Hostname of build master.
# Only used when initializing slaves.
# If not already set in environment, defaults to current machine for demo purposes.
# FIXME: find some nicer way of doing this, so demo case is not so different from real case.
MASTER=${MASTER:-$HOSTNAME}

# Remap hostnames if needed (e.g. if naming system changes, or during testing, or if in container)
case $HOSTNAME in
*-temp-*) HOSTNAME=${HOSTNAME%-temp*}; echo "This slave is running in an lxc container, so pretending hostname is $HOSTNAME";;
esac

echo "Slave advertising hostname $HOSTNAME, using $MASTER as master"

run_in_sandbox() {
    (
        cd $VIRTUAL_ENV
        . bin/activate
        "$@"
    )
}

install_prereqs() {
    if test -x "`which sudo 2>/dev/null`" && ! grep $BUILDUSER.ALL /etc/sudoers
    then
        echo "============================="
        echo "EVIL WARNING: giving user $BUILDUSER the ability to install/remove packages without password"
        # Needed to run 'install_prereqs/uninstall_prereqs' build steps for each project.
        echo "$BUILDUSER ALL=(ALL) NOPASSWD: ALL" | sudo tee -a /etc/sudoers
        echo "============================="
    fi

    # Commonly needed packages we want on the slave but that are not required by buildbot itself.
    case $_os in
    ubu12*) GIT=git;
            sudo apt-get install -y $GIT devscripts build-essential ccache wget;;
    ubu*) GIT=git-core;
            sudo apt-get install -y $GIT devscripts build-essential ccache wget;;
    cygwin) apt-cyg install make ccache;;
    *) abort "unknown OS";;
    esac

    if ! automake --version
    then
        case $_os in
        ubu*)   sudo apt-get install -y automake;;
        cygwin) apt-cyg install automake;;
        esac
    fi

    if ! patch --version
    then
        case $_os in
        ubu*)   sudo apt-get install -y patch;;
        cygwin) apt-cyg install patch;;
        esac
    fi

    # Packages needed by buildbot itself.
    if ! virtualenv --version > /dev/null 2>&1
    then
        case $_os in
        ubu*) sudo apt-get install -y python-dev python-virtualenv ;;
        cygwin) easy_install pip virtualenv ;;   # README already had you install python
        esac
    fi
    if ! gcc --version > /dev/null 2>&1
    then
        case $_os in
        ubu*) sudo apt-get gcc ;;
        cygwin) apt-cyg install gcc gcc4 ;;
        esac
    fi
}

install_buildslave() {
    install_prereqs

    (
    mkdir -p $TOP
    cd $TOP
    test -d $_os || virtualenv --no-site-packages $_os
    )
    if false
    then
        # easy_install is usually sufficient; buildbot slave code changes
        # very slowly, no need to run latest.
        # But guess what?  It fails if buildbot.net is down.
        run_in_sandbox easy_install buildbot-slave
    else
       (
        cd $VIRTUAL_ENV
        . bin/activate

        # Here's how to install from a source tarball.
        wget -c http://buildbot.googlecode.com/files/buildbot-slave-0.8.7.tar.gz
        tar -xzvf buildbot-slave-0.8.7.tar.gz
        cd buildbot-slave-0.8.7
        python setup.py install
        cd ..
        )
    fi
}

# Helper to split the given product spec into name and port,
# and set $VIRTUAL_ENV/$slavename to the directory containing its bot
parse_product() {
    projname=$1
    ####### PORT NUMBERS
    # It's hard to keep port numbers straight for multiple projects,
    # so let's assign each project a slot number,
    # and use 8010 + slotnum for the http port,
    # 9010 + slotnum for the slave port,
    # etc.  common/SimpleConfig.py duplicates this code.
    if ! test -f $SRC/$1/slot.txt
    then
        abort "$SRC/$1/slot.txt must contain the unique port offset for this project. (0 for http_port=8010, 1 for 8011, etc.)"
    fi
    slot=`cat $SRC/$1/slot.txt`
    #httpport=`expr $slot + 8010`
    slaveport=`expr $slot + 9010`
    slavename=$projname-$HOSTNAME
}

sanity_check() {
    dups=`cat */slot.txt | sort | uniq -c | awk '$1 > 1 {print $2}'`
    if test "$dups"
    then
        abort "Slots have duplicate values: $dups"
    fi
}

init_slave() {
    sanity_check
    parse_product $1
    run_in_sandbox buildslave create-slave $VIRTUAL_ENV/$slavename ${MASTER}:$slaveport $slavename $SLAVE_PASSWD
    # Create symlink so slave build steps can find buildshim
    ln -s $SRC/$projname/buildshim $VIRTUAL_ENV/$slavename/buildshim
    install_service $1
}

# Run service in foreground with no extra processes (e.g. subshells) in memory
do_run() {
    parse_product $1
    CCACHE_DIR="$VIRTUAL_ENV/$slavename/ccache.dir"
    if ! test -d $CCACHE_DIR
    then
        mkdir $CCACHE_DIR
    fi
    export CCACHE_DIR
    xpidf="$VIRTUAL_ENV/$slavename/twistd.pid"
    if test -f "$xpidf"
    then
        xpid=`cat "$xpidf"`
        if test -d /proc/$xpid && ps augxww $xpid | grep twistd
        then
            abort "buildslave with pid $xpid already running?"
        else
            echo "Removing stale PID file $xpidf (where did it come from?)"
            rm "$VIRTUAL_ENV/$slavename/twistd.pid"
        fi
    fi

    cd $VIRTUAL_ENV
    pwd
    ls -l
    ls -l bin
    . bin/activate
    exec twistd --pidfile $VIRTUAL_ENV/$slavename/twistd.pid --nodaemon --no_save -y $VIRTUAL_ENV/$slavename/buildbot.tac

    echo Done
    sleep 30000
}

uninit_slave() {
    uninstall_service $1
    parse_product $1
    # Better stop it before doing this
    rm -rf $VIRTUAL_ENV/$slavename
}

# Add this project's buildslave to the system service manager.
install_service() {
    parse_product $1

    case $_os in
    ubu*)
    (
        cat  <<_EOF_
description "ciwrap buildbot slave startup for $projname"
author "Dan Kegel <dank@kegel.com>"

start on (started network-interface or started network-manager or started networking)
stop on (stopping network-interface or stopping network-manager or stopping networking)
respawn
console log
setuid $BUILDUSER
exec sh $SRC/bslave.sh run $projname
_EOF_
    ) | sudo tee /etc/init/buildslave-$_os-$projname.conf
    ;;
    cygwin)
        # Must use "run as administrator" to run the cygwin terminal that runs this script!
        cygrunsrv -I buildslave-$_os-$projname --path /bin/sh --args "$SRC/bslave.sh run $projname"
        ;;
    *) abort "unsupported OS $_os";;
    esac
}

uninstall_service() {
    parse_product $1
    case $_os in
    ubu*)
        sudo rm -f /etc/init/buildslave-$_os-$projname.conf
        ;;
    cygwin)
        # Must use "run as administrator" to run the cygwin terminal that runs this script!
        cygrunsrv --remove buildslave-$_os-$projname || true
        ;;
    *) abort "unsupported OS $_os";;
    esac
}

uninstall() {
    rm -rf $TOP
}

case "$1" in
    prereqs)   install_prereqs    ;;   # for testing
    install)   install_buildslave ;;
    init)      init_slave "$2"    ;;
    run)       do_run "$2"        ;;
    uninit)    uninit_slave "$2"  ;;
    uninstall) uninstall          ;;
    *) usage; abort "bad arg $1"  ;;
esac
