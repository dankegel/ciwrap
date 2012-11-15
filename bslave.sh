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

abort() {
    echo fatal error: $*
    exit 1
}

detect_os() {
    # Detect OS
    case "`uname -s`" in
    Linux)
        case "`lsb_release -ds`" in
        "Ubuntu 10.04"*) echo ubu1004;;
        "Ubuntu 12.04"*) echo ubu1204;;
        *) abort "unrecognized linux";;
        esac
        ;;
    Darwin)
        case `sw_vers -productVersion` in
        10.7.*) echo osx107;;
        *) abort "unrecognized mac";;
        esac
        ;;
    CYGWIN*WOW64) echo cygwin;;
    CYGWIN*)      echo cygwin;;
    *) abort "unrecognized os";;
    esac
}
set -x
set -e

# Where this script lives
SRC=`dirname $0`
# Get an absolute directory (for the case where it's run with 'sh bslave.sh')
SRC=`cd $SRC; pwd`

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

virtualenv=virtualenv
_os=`detect_os`
case $_os in
cygwin)
    if test $BUILDUSER = SYSTEM
    then
        echo "FIXME: Cygwin service, no idea what real user is, hope it's 'buildbot'."
        BUILDUSER=buildbot
        BUILDUSERHOME=`eval echo ~$BUILDUSER`
    fi
    ;;
osx*)
    virtualenv=virtualenv-2.7
    ;;
esac

# Working area; holds all the state of the installed buildbot slave instances
TOP=$BUILDUSERHOME/slave-state

# same password for all slaves currently
SLAVE_PASSWD=`awk '/slavepass/ {print $3}' $BUILDUSERHOME/myconfig.json | tr -d '[",]' `

# Normally exported by virtualenv's activate, but we need it at other times, too
VIRTUAL_ENV=$TOP/$_os

# Hostname of this slave (without domain, assuming this is on a LAN and not the internet)
# Convert to lowercase, since macs like to capitalize things sometimes,
# and hostnames are case-insensitive but slave names aren't.
HOSTNAME=`hostname -s || hostname | tr -d '\015'`
HOSTNAME=`echo $HOSTNAME | tr -d '\015' | tr "[:upper:]" "[:lower:]" `
echo HOSTNAME is ${HOSTNAME}

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

    # Some packages are the same on all systems
    for pkg in autoconf automake patch
    do
        if ! $pkg --version
        then
            case $_os in
            ubu*)   sudo apt-get install -y $pkg;;
            cygwin) apt-cyg install $pkg;;
            osx*)   sudo port install $pkg;;
            esac
        fi
    done
 
    if ! gcc --version > /dev/null 2>&1
    then
        case $_os in
        ubu*) sudo apt-get gcc ;;
        cygwin) apt-cyg install gcc gcc4 ;;
        osx*) sudo port install gcc46 ;;
        esac
    fi

    if ! git --version
    then
        case $_os in
        ubu1004) sudo apt-get install -y git-core;;
        ubu*)    sudo apt-get install -y git;;
        cygwin)  apt-cyg install git;;
        osx*)    sudo port install git-core;;
        esac
    fi

    if ! $virtualenv --version > /dev/null 2>&1
    then
        case $_os in
        ubu*) sudo apt-get install -y python-dev python-virtualenv ;;
        cygwin) easy_install pip virtualenv ;;   # README already had you install python
        osx*)   
            sudo port install python27 py27-virtualenv
            sudo port select --set python python27
            ;;
        esac
    fi

    case $_os in
    ubu*)   sudo apt-get install -y devscripts build-essential ccache wget;;
    cygwin) apt-cyg      install make ccache wget;;
    osx*)   sudo port    install gmake ccache wget;;
    *) abort "unknown OS";;
    esac
}

install_buildslave() {
    install_prereqs

    (
    mkdir -p $TOP
    cd $TOP
    test -d $_os || $virtualenv --no-site-packages $_os
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

# Given the project name, set the variables 'slaveport' and 'slavename'
# such that $VIRTUAL_ENV/$slavename is the directory containing its bot,
# and $slaveport is the port the slave should connect to the master on.
parse_project() {
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
    if ! test -f $BUILDUSERHOME/myconfig.json
    then
        abort "Can't initialize if you haven't put your secrets file at $BUILDUSERHOME/myconfig.json"
    fi
}

init_slave() {
    sanity_check
    parse_project $1
    run_in_sandbox buildslave create-slave $VIRTUAL_ENV/$slavename ${MASTER}:$slaveport $slavename $SLAVE_PASSWD
    # Create symlink so slave build steps can find buildshim
    ln -s $SRC $VIRTUAL_ENV/$slavename/srclink
    install_service $1
}

# Run service in foreground with no extra processes (e.g. subshells) in memory
do_run() {
    parse_project $1

    case $_os in
    ubu10*)
        # ubuntu 10.04's upstart does not log job output, so let's do that here if we're running under upstart
        if test "$UPSTART_JOB"
        then
            if ! test -d /var/log/upstart
            then
                sudo mkdir /var/log/upstart
            fi
            LOGFILE=/var/log/upstart/buildslave-$_os-$projname.log
            if ! test -w $LOGFILE
            then
                sudo touch $LOGFILE
                sudo chown $BUILDUSER $LOGFILE
            fi
            exec >> $LOGFILE 2>&1
        fi
        ;;
    esac

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
    . bin/activate
    exec twistd --pidfile $VIRTUAL_ENV/$slavename/twistd.pid --nodaemon --no_save -y $VIRTUAL_ENV/$slavename/buildbot.tac

    echo Done
}

uninit_slave() {
    uninstall_service $1
    parse_project $1
    # Better stop it before doing this
    rm -rf $VIRTUAL_ENV/$slavename
}

# Add this project's buildslave to the system service manager.
install_service() {
    parse_project $1

    case $_os in
    ubu10*)
    (
        cat  <<_EOF_
description "ciwrap buildbot slave startup for $projname"
author "Dan Kegel <dank@kegel.com>"

start on (started network-interface or started network-manager or started networking)
stop on (stopping network-interface or stopping network-manager or stopping networking)
respawn
exec su -s /bin/sh -c 'exec "\$0" "\$@"' $BUILDUSER -- sh $SRC/bslave.sh run $projname
_EOF_
    ) | sudo tee /etc/init/buildslave-$_os-$projname.conf
        ;;
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
    osx*)
        sed "s,\$SRC,$SRC,;s,\$BUILDUSER,$BUILDUSER,;s,\$PROJNAME,$projname," < $SRC/slave.plist | sudo tee /Library/LaunchDaemons/net.buildbot.slave.$projname.plist
        sudo launchctl load /Library/LaunchDaemons/net.buildbot.slave.$projname.plist
        # Unlike other two systems, on the Mac, the service starts as soon as it's loaded.
        ;;
    *) abort "unsupported OS $_os";;
    esac
}

uninstall_service() {
    parse_project $1
    case $_os in
    ubu*)
        sudo rm -f /etc/init/buildslave-$_os-$projname.conf
        ;;
    cygwin)
        # Must use "run as administrator" to run the cygwin terminal that runs this script!
        cygrunsrv --remove buildslave-$_os-$projname || true
        ;;
    osx*)
        sudo launchctl unload /Library/LaunchDaemons/net.buildbot.slave.$projname.plist
        sudo rm -f /Library/LaunchDaemons/net.buildbot.slave.$projname.plist
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
