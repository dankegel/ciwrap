#!/bin/sh

usage()
{
    echo "usage: 'sh badd-sudoer.sh --I-do-not-care-about-security username'"
    echo "Use with extreme caution."
    echo "Adds given user to /etc/suders without password and without restrictions."
    echo ""
    echo "Power!  Unlimited POWER!  -- Emporer Palpatine"
}

case "$1" in
"--I-do-not-care-about-security")
    # OK
    ;;

*)  usage
    exit 0
    ;;
esac

case "$2" in
"") usage
    exit 0
    ;;
*)
    # OK
    ;;
esac

echo "$2 ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
