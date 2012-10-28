#!/bin/sh
# Operate on the names of all the log files for a given project
# Note: not all of these log files will exist.
prod=$1
case "$prod" in
"") echo "missing project; usage: sh blog.sh project command"; exit 1;;
esac
shift

case "$1" in
"") echo "missing command; usage: sh blog.sh project command"; exit 1;;
esac

abort() {
    echo fatal error: $1
    exit 1
}

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
