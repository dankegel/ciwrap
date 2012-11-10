#!/bin/sh

usage() {
cat << _EOF_
Start or stop all the buildbot masters and slaves on this machine
Usage:
    sh bservice.sh start|stop|status
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

list() {
    case $_os in
    ubu*)
        initctl list | egrep 'buildslave|buildmaster' | awk '{print $1}' ;;
    cygwin)
        cygrunsrv --list | egrep 'buildslave|buildmaster' ;;
    osx*)
        sudo launchctl list | egrep 'net.buildbot' | awk '{print $3}' ;;
    *)
        echo "Unknown os $_os"; exit 1;;
    esac
}

verb=$1
_os=`detect_os`

case "$verb" in
"") usage; exit 0;;
list) list ; exit 0;;
status)
    case $_os in
    cygwin) verb=query ;;
    osx*) verb=list ;;
    esac
esac

for service in `list`
do
    case $_os in
    ubu*) sudo initctl $verb $service ;;
    cygwin) cygrunsrv --$verb $service ;;
    osx*) sudo launchctl $verb $service ;;
    *)
        echo "Unknown os $_os"; usage; exit 1;;
    esac
done
