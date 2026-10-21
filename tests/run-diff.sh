#!/bin/sh
set -u
cd "$(dirname "$0")/.."
fail=0
if [ ! -e zig-out/lib/libgstreamer-1.0.so.0 ]; then echo "missing zig-out/lib/libgstreamer-1.0.so.0"; exit 1; fi
for t in zig-out/bin/diff-*; do
    n=$(basename "$t")
    want=$("$t" 2>&1 | sed -E 's/\(([^:()]+):[0-9]+\)/(\1:PID)/; s/[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}:/TIME:/')
    got=$(LD_LIBRARY_PATH="$PWD/zig-out/lib" "$t" 2>&1 | sed -E 's/\(([^:()]+):[0-9]+\)/(\1:PID)/; s/[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}:/TIME:/')
    if [ "$want" = "$got" ]; then
        echo "same $n"
    else
        echo "DIFF $n"
        printf '%s\n' "$want" > "zig-out/$n.want"
        printf '%s\n' "$got" > "zig-out/$n.got"
        diff "zig-out/$n.want" "zig-out/$n.got" | head -20
        fail=1
    fi
done
exit $fail
