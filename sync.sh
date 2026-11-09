#!/bin/sh
# Copy the addon into the live WoW AddOns directories (the installed addon is a
# copy — after syncing, /reload in game; a brand-new install needs a client restart).
set -e
for FLAVOR in _anniversary_ _classic_era_ _classic_beta_ _forever_; do
  DEST="/Applications/World of Warcraft/$FLAVOR/Interface/AddOns/Disenchanter"
  mkdir -p "$DEST"
  cp Disenchanter.toc Disenchanter_Compat.lua Disenchanter_Data.lua Disenchanter_DB.lua Disenchanter.lua "$DEST/"
  echo "synced to $DEST"
done
