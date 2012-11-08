#!/bin/sh
# Operate on the names of all the log files for a given project
# Note: not all of these log files will exist.

usage() {
cat << _EOF_
Display all logs related to a given buildbot.
Usage:
    sh blog.sh project command
where command is "tail" or "grep foo" or whatever you'd like to do to the logs.
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

prod=$1
case "$prod" in
"") echo "missing project; usage: sh blog.sh project command"; exit 1;;
esac
shift

case "$1" in
"") echo "missing command; usage: sh blog.sh project command"; exit 1;;
esac

_os=`detect_os`
case $_os in
ubu*)
    sudo chmod 644 /var/log/upstart/build*
    logs="/var/log/upstart/buildmaster-$prod.log \
         /var/log/upstart/buildslave-*-$prod.log \
         $HOME/master-state/*/$prod/twistd.log \
         $HOME/slave-state/*/$prod-*/twistd.log"
    ;;
cygwin)
    logs="/var/log/buildmaster-$prod.log \
         /var/log/buildslave-*-$prod.log \
         $HOME/master-state/*/$prod/twistd.log \
         $HOME/slave-state/*/$prod-*/twistd.log"
    ;;
osx*)
    # Sigh.
    grep net.buildbot.*.$prod < /var/log/system.log > /tmp/$prod.log
    logs="/tmp/$prod.log \
         $HOME/master-state/*/$prod/twistd.log \
         $HOME/slave-state/*/$prod-*/twistd.log"
    ;;
*)
    abort "unknown os $_os"
    ;;
esac

for log in $logs
do
   echo "=== $op $log ==="
   echo ""
   $* $log
   echo ""
done
