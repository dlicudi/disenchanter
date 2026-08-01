#!/bin/sh
# Copy the addon into the live WoW AddOns directory (the installed addon is a
# copy — after syncing, /reload in game).
set -e
DEST="/Applications/World of Warcraft/_anniversary_/Interface/AddOns/Disenchanter"
mkdir -p "$DEST"
cp Disenchanter.toc Disenchanter.lua "$DEST/"
echo "synced to $DEST"
