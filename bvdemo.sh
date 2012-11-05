#!/bin/sh
# Example of how to use bmaster.sh and bvslave-lxc.sh
# once you've created foo/{buildshim,master.cfg,slot.txt}
# You'll usually give these commands by hand.
# No commands need be given at system startup; the bots will start automatically.
set -e
set -x

projects="pyflakes"

guest="ubu1204"

install_and_start()
{
    if ! test -d /data/lxc
    then
        echo "Please create directory /data/lxc on a volume with several gigabytes of free space"
        exit 1
    fi

    sh bmaster.sh install
    sh bvslave-lxc.sh $guest install

    for proj in $projects
    do
        # Could loop over guest OS's here
        sh bvslave-lxc.sh $guest init $proj
        sh bmaster.sh init $proj
    done

    sh bservice.sh start

    # Eyeball the bots' output to see if there are any obvious errors
    for proj in $projects
    do
        echo =========== Last ten lines of logs for $proj ============
        sleep 1
        sh blogs.sh $proj tail
    done
}

stop_and_uninstall()
{
    sh bservice.sh stop || true
    for proj in $projects
    do
        sh bmaster.sh uninit $proj || true
        sh bvslave-lxc.sh $guest uninit $proj || true
    done
    sh bmaster.sh uninstall || true
    sh bvslave-lxc.sh $guest uninstall || true
}

case $1 in
install) install_and_start ;;
uninstall) stop_and_uninstall ;;
*) echo Usage: $0 'install|uninstall';;
esac

