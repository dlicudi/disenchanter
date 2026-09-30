#!/bin/sh
set -eu
m=$(luac -o /dev/null -l "${1:?file required}" | grep -o '[0-9]* upvalues' | sort -rn | head -1 | cut -d' ' -f1)
[ "$m" -lt 58 ] || { echo "upvalue check failed: $m" >&2; exit 1; }
echo "upvalue check OK (max $m, game cap 60)"
