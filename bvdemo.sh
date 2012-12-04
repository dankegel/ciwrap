#!/bin/sh
# Example of how to use bmaster.sh and bvslave-lxc.sh
# once you've created foo/{buildshim,master.cfg,slot.txt}
# You'll usually give these commands by hand.
# No commands need be given at system startup; the bots will start automatically.
set -e
set -x

projects="hellozlib.master"

guests="ubu1004 ubu1204"

install_and_start()
{
    if ! test -d /data/lxc
    then
        echo "Please create directory /data/lxc on a volume with several gigabytes of free space"
        exit 1
    fi
    if ! test -f ~/myconfig.json
    then
        abort "Can't initialize if you haven't put your secrets file at ~/myconfig.json"
    fi

    sh bmaster.sh install
    for guest in $guests
    do
        sh bvslave-lxc.sh $guest install
    done
    for proj in $projects
    do
        for guest in $guests
        do
            sh bvslave-lxc.sh $guest init $proj
        done
    done

    for proj in $projects
    do
        sh bmaster.sh init $proj
    done

    sh bservice.sh start

    # It seems to take the slaves 30 seconds to wake up and get their DNS working
    # FIXME
    sleep 30

    # Eyeball the bots' output to see if there are any obvious errors
    for proj in $projects
    do
        echo =========== Last ten lines of logs for $proj ============
        sleep 3
        sh blogs.sh $proj tail
    done
}

stop_and_uninstall()
{
    sh bservice.sh stop || true
    for proj in $projects
    do
        sh bmaster.sh uninit $proj || true
        for guest in $guests
        do
            sh bvslave-lxc.sh $guest uninit $proj || true
        done
    done
    sh bmaster.sh uninstall || true
    for guest in $guests
    do
        sh bvslave-lxc.sh $guest uninstall || true
    done
}

case $1 in
install) install_and_start ;;
uninstall) stop_and_uninstall ;;
*) echo Usage: $0 'install|uninstall';;
esac
