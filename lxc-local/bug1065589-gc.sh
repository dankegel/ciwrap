#!/bin/sh
# Script for one round of garbage collection to work around leak in lxc-start
# See https://bugs.launchpad.net/ubuntu/+source/lxc/+bug/1065589
set -x

# Get list of services to kill
# Output is like
#  network-interface-security (network-interface/veth8BiZTe) start/running
LIST1=/tmp/bogus-network-interface-security.$$
initctl list | awk '/network-interface-security .*veth/ {print $2}' | sed 's,.*/,,;s/)//' > $LIST1

LIST2=/tmp/bogus-network-interface.$$
# network-interface (vethNWRfGC) start/running
initctl list | awk '/network-interface \(veth.*\).*/ {print $2}' | tr -d '()'  > $LIST2

if test `wc -l < $LIST1` = 0 && test `wc -l < $LIST2` = 0
then
    echo No bogus interfaces found.
else
    # Get list of PIDs that might still be using them
    pids=`ps -e -o pid,command | grep 'lxc-start ' | grep -v grep | awk '{print $1}'`

    # Wait until all those PIDs go away
    for p in $pids
    do
        while grep lxc-start /proc/$p/cmdline
        do
            sleep 60
        done
    done

    # Kill the services
    for interface in `cat $LIST1`
    do
        sudo stop network-interface-security JOB=network-interface INTERFACE=$interface
    done
    for interface in `cat $LIST2`
    do
        sudo stop network-interface INTERFACE=$interface
    done
fi
rm /tmp/bogus-network*.$$
