#!/bin/sh
# Example of how to use bmaster.sh and bslave.sh
# once you've created foo/{buildshim,master.cfg,slot.txt}
# You'll usually give these commands, or ones like them, by hand.
# No commands need be given at system startup; the bots will start automatically.

set -e
set -x

projects="pyflakes hellozlib"

install_and_start()
{
    sh bmaster.sh install
    sh bslave.sh install

    for proj in $projects
    do
        sh bmaster.sh init $proj
        sh bslave.sh init $proj
    done

    sh bservice.sh start

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
        sh bslave.sh uninit $proj || true
    done
    sh bmaster.sh uninstall || true
    sh bslave.sh uninstall || true
}

case $1 in
install) install_and_start ;;
uninstall) stop_and_uninstall ;;
*) echo Usage: $0 'install|uninstall';;
esac
