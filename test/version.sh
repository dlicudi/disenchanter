#!/bin/sh
set -eu
l=$(sed -n 's/^local VERSION.*"\([^"]*\)".*/\1/p' Disenchanter.lua)
t=$(sed -n 's/^## Version:[[:space:]]*//p' Disenchanter.toc)
p=$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' package.json)
[ -n "$l" ] && [ "$l" = "$t" ] && [ "$l" = "$p" ] || { echo "version mismatch: $l $t $p" >&2; exit 1; }
echo "version check OK ($l)"
