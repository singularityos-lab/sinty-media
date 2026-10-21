#!/bin/sh
set -u
cd "$(dirname "$0")/.."
fail=0
for t in zig-out/bin/diff-*; do
    n=$(basename "$t")
    want=$("$t" 2>&1)
    got=$(LD_LIBRARY_PATH="$PWD/zig-out/lib" "$t" 2>&1)
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
