#!/bin/sh
prod=$1
shift

for CCACHE_DIR in $HOME/slave-state/*/${prod}*/ccache.dir
do
    export CCACHE_DIR
    echo "=== ccache $* $CCACHE_DIR ==="
    echo ""
    ccache $*
    echo ""
done
