#!/bin/sh
# Start or stop all the buildbot masters and slaves on this machine
verb=$1

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

list() {
    case $_os in
    ubu*)
        initctl list | egrep 'buildslave|buildmaster' | awk '{print $1}' ;;
    cygwin) 
        cygrunsrv --list | egrep 'buildslave|buildmaster' ;;
    *)
        echo "Unknown os $_os"; exit 1;;
    esac
}

cygverb=$verb

case "$verb" in
"") echo usage: $0 'start|stop|status'; exit 0;;
list) list ; exit 0;;
status) cygverb=query ;;
esac

for service in `list`
do
    case $_os in
    ubu*) sudo initctl $verb $service ;;
    cygwin) cygrunsrv --$cygverb $service ;;
    *)
        echo "Unknown os $_os"; exit 1;;
    esac
done
