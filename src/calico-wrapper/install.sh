#!/bin/sh

set -e

rm -f /host/opt/cni/bin/calico-wrapper
cp /calico-wrapper /host/opt/cni/bin/

# Sleep forever
tail -f /dev/null
