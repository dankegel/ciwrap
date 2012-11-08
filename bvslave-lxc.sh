#!/bin/sh
# Run bslave.sh inside an lxc container
# Main container for a given OS is identical for all projects built by this
# slave, and is never started or written to after creation.
# Instead, lightweight clones of it are created before each build by
# lxc-start-ephemeral.
#
# Copyright Oblong.com 2012 (Dan Kegel)

usage() {

cat <<_EOF_
Convenience script for lxc-based buildbot slaves; handy place to hide nasty details.
Usage:
  bvslave-lxc.sh os install [kitchen_sink]
  bvslave-lxc.sh os init projectname
  bvslave-lxc.sh os uninit projectname
  bvslave-lxc.sh os uninstall

where osname is ubu1004 or ubu1204.
If kitchen_sink is given, the resulting VM will be loaded with a largish set of system packages.
_EOF_

}

set -e
set -x

if test "$LOGNAME" = ""
then
    BUILDUSER=`id -nu`
    BUILDUSERHOME=`eval echo ~$BUILDUSER`
else
    BUILDUSER=$LOGNAME
    BUILDUSERHOME=$HOME
fi

# Working area; holds all the state of the installed buildbot slave instances
TOP=$BUILDUSERHOME/slave-state

# Where this script lives
SRC=`dirname $0`
# Get an absolute directory (for the case where it's run with 'sh bvslave-lxc.sh')
SRC=`cd $SRC; pwd`

abort() {
    echo fatal error: $*
    exit 1
}

_os=$1
_cmd=$2
_prod=$3

# Hostname of this slave (without domain)
HOSTNAME=`hostname -s`

# Hostname of build master.
# If not already set in environment, defaults to current machine for demo purposes.
# FIXME: find some nicer way of doing this, so demo case is not so different from real case.
# Only used when initializing slaves.
MASTER=${MASTER:-$HOSTNAME}

# Use patched version of lxc-start-ephemeral
PATH=$SRC/lxc-local:$PATH

case $_os in
ubu1004) GUEST_DISTRO=ubuntu GUEST_VERSION=lucid   HOSTNAME=$HOSTNAME-ubu1004;;
ubu1204) GUEST_DISTRO=ubuntu GUEST_VERSION=precise HOSTNAME=$HOSTNAME-ubu1204;;
*) abort "Unknown OS $_os, please specify ubu1004 or ubu1204 as 1st arg"
esac

echo "Running $GUEST_DISTRO $GUEST_VERSION in lxc, advertising hostname $HOSTNAME, using $MASTER as master"

# must match value in bslave.sh
VIRTUAL_ENV=$TOP/$_os

if ! egrep -q "Ubuntu 12.04|quantal" /etc/issue
then
    abort "Sorry, only Ubuntu 12.04 can host lxc at the moment"
fi

install_slave() {
    case "$1" in
    kitchen_sink) preload_deps=1;;
    "") ;;
    *) abort "You can't install just one.  Maybe you meant init?  Or did you mean to say kitchen_sink to preload deps?";;
    esac

    if [ -d /var/lib/lxc/$HOSTNAME ]
    then
        abort "LXC container $HOSTNAME already exists"
    fi

    if [ ! -f $BUILDUSERHOME/.ssh/authorized_keys ]
    then
        abort "You need to have .ssh/authorized_keys set up to accept logins from the outer slave"
    fi
    if [ ! -f $SRC/bslave.sh ]
    then
        abort "$SRC/bslave.sh not found"
    fi

    # Packages needed on host to run lxc properly
    pkgs=
    for pkg in lxc yum curl
    do
        if ! dpkg-query -W $pkg
        then
            pkgs="$pkgs $pkg"
        fi
    done
    if test "$pkgs" != ""
    then
        sudo apt-get install -y $pkgs
    fi

    LXCTEMPLATES=/usr/lib/lxc/templates
    if ! test -d $LXCTEMPLATES
    then
        LXCTEMPLATES=/usr/share/lxc/templates
    fi
    if ! test -d $LXCTEMPLATES
    then
        abort "lxc templates not found"
    fi

    case $GUEST_DISTRO in
    ubuntu) verop="-r";;
    centos) verop="-R";;
    esac

    # Share this user's home directory with the virtual machine (!)
    # This only works in ubuntu for now, centos lacks that option
    # (Later, must also specify --bdir $HOME to lxc-start-ephemeral.)
    sudo lxc-create -t $GUEST_DISTRO -n $HOSTNAME -- $verop $GUEST_VERSION --bindhome $LOGNAME

    # Install slaves on virtual machine, making use of the fact that $HOME is
    # mounted for this same user inside the container, and hoping that $TOP is in $HOME.
    # Need working network, so can't just do 'lxc-start cmd'
    sudo lxc-start -o /tmp/$HOSTNAME.log -n $HOSTNAME -d
    sleep 1
    cat /tmp/$HOSTNAME.log
    lxc-ssh $HOSTNAME sh $SRC/fix-dns.sh
    lxc-ssh $HOSTNAME sudo apt-get -y update
    lxc-ssh $HOSTNAME sudo locale-gen en_US.UTF-8
    if test "$preload_deps" = "1"
    then
        lxc-ssh $HOSTNAME sudo sh $SRC/preload-deps.sh
    fi
    lxc-ssh $HOSTNAME sh $SRC/bslave.sh install
    sudo lxc-stop -n $HOSTNAME
}

# Helper to split the given project spec into name and port,
# and set $VIRTUAL_ENV/$slavename to the directory containing its bot
# (ports don't matter here, so they're omitted from data)
parse_project() {
    projname=$1
    case "$projname" in
    "") abort "must specify a project";;
    esac

    slavename=$projname-$HOSTNAME

    OVERLAY_DIR=/data/lxc/$HOSTNAME-temp-$projname-unique
    LXC_NAME=$HOSTNAME-temp-$projname-unique
    LXC_DIR=/var/lib/lxc/$LXC_NAME
}

init_slave() {
    parse_project $1
    sudo lxc-start -n $HOSTNAME -- su $LOGNAME -c "env MASTER=$MASTER sh $SRC/bslave.sh init $projname"
    install_service $1
}

do_run() {
    parse_project $1
    if ! test -d /data/lxc
    then
        abort "Need to create /data/lxc directory where ephemeral containers' files will be stored"
    fi
    if ! test -f $VIRTUAL_ENV/$slavename/buildbot.tac
    then
        abort "No $VIRTUAL_ENV/$slavename/buildbot.tac, aborting"
    fi

    if [ -d $LXC_DIR ] ; then
        echo "lxc container $LXC_NAME already exists, destroying"
        sudo lxc-destroy -n $LXC_NAME
    fi

    # We can't use tmpfs for our overlay, so set up a real directory.
    # FIXME: cleaning up the real overlay directory can be slow, should this be a filesystem?
    if test -d "$OVERLAY_DIR"
    then
        sudo rm -rf --one-file-system "$OVERLAY_DIR"
    fi
    sudo mkdir -p "$OVERLAY_DIR"

    sudo bash -x $SRC/lxc-local/lxc-start-ephemeral \
             --overlaydir "$OVERLAY_DIR" --name $LXC_NAME \
             --bdir $BUILDUSERHOME --orig $HOSTNAME --ssh-key $BUILDUSERHOME/.ssh/id_rsa --user $BUILDUSER -U aufs \
             -- \
             sh $SRC/bslave.sh run $projname

    if test -d "$OVERLAY_DIR"
    then
        sudo rm -rf --one-file-system "$OVERLAY_DIR"
    fi
}

do_stop() {
    parse_project $1
    if [ -d $LXC_DIR ] ; then
        echo "Stopping lxc container $LXC_NAME"
        sudo lxc-stop -n $LXC_NAME
    fi
}

uninit_slave() {
    uninstall_service $1
    do_stop $1
    sudo lxc-start -n $HOSTNAME -- su $LOGNAME -c "sh $SRC/bslave.sh uninit $1"
}

uninstall_slave() {
    if test "$1" != ""
    then
        abort "You can't uninstall just one.  You probably meant uninit."
    fi
    sudo lxc-destroy -f -n $HOSTNAME || true
    sh $SRC/bslave.sh uninstall
}

# Add this project's buildslave to the system service manager.
install_service() {
    parse_project $1
    (
        cat  <<_EOF_
description "ciwrap lxc buildbot slave startup for $projname"
author "Dan Kegel <dank@kegel.com>"

start on started network-interface INTERFACE=eth0
stop on stopping network-interface INTERFACE=eth0
respawn
console log
setuid $BUILDUSER
exec sh $SRC/bvslave-lxc.sh $_os run $projname

# kludge: do the real stopping in pre-stop until we figure out the fork/pid stuff
pre-stop exec sh $SRC/bvslave-lxc.sh $_os stop $projname
_EOF_
    ) | sudo tee /etc/init/buildslave-$_os-$projname.conf
}

uninstall_service() {
    parse_project $1
    sudo rm /etc/init/buildslave-$_os-$projname.conf
}

case "$_cmd" in
    install) install_slave $_prod;;
    init) init_slave $_prod;;
    run) do_run $_prod;;
    stop) do_stop $_prod;;
    uninit) uninit_slave $_prod;;
    uninstall) uninstall_slave $_prod;;

    *) usage; abort "bad arg $_cmd";;
esac
