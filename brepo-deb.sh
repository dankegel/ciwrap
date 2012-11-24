#!/bin/sh

usage() {
cat << _EOF_
Manage a local .deb repository.
Simple wrapper around reprepro.
Usage:
    sh brepo-deb.sh install
    sh brepo-deb.sh init
    sh brepo-deb.sh add file...
Assumes you're uploading packages built for the local OS ($_os).
_EOF_
}

SRCFILE="`readlink $0 2>/dev/null || echo $0`"
SRC="`dirname $SRCFILE`"
SRC="`cd $SRC; pwd`"
. $SRC/bs_funcs.sh

_os=`bs_detect_os`

bs_os_codename() {
    case $1 in
    ubu1004) echo lucid;;
    ubu1204) echo precise;;
    *) bs_abort "bs_os_codename: don't know codename for $1 yet";;
    esac
}

verb="$1"
if ! test "$verb"
then
    usage
    bs_abort "missing verb"
fi
shift

set -e
set -x

do_install() {
    reprepro --version || sudo apt-get install -y reprepro
}

do_init() {
    # The intent is to have directories under /var/repobot
    # raw for bare tarballs, yum for a yum repo, apt for an apt repo, etc.
    sudo mkdir -p /var/repobot/apt/conf
    # fixme: generate this
    sudo cp apt-distributions /var/repobot/apt/conf/distributions
}

do_add() {
    codename=`bs_os_codename $_os`
    sudo su -c "reprepro -Vb /var/repobot/apt includedeb $codename $@"
}

case $verb in
install)
    do_install
    ;;
init)
    do_init
    ;;
add)
    do_add $@
    ;;
*)
    usage
    bs_abort "unknown verb $verb"
    ;;
esac
