#!/usr/bin/env bash
# Usage: .github/scripts/release-check.sh
#
# For each entry of held-packages.json, builds its `releaseWhen` attribute
# (default: the entry's name) from the current nixos-unstable. Prints
# "release <name>" for each that builds again and "held <name> <days>" for the
# others. Run from the repository root.
set -uo pipefail

system=$(nix eval --raw --impure --expr builtins.currentSystem)
today=$(date -u +%s)

for name in $(jq -r 'keys[]' held-packages.json); do
  attr=$(jq -r --arg n "$name" '.[$n].releaseWhen // $n' held-packages.json)
  since=$(jq -r --arg n "$name" '.[$n].since' held-packages.json)
  days=$(((today - $(date -u -d "$since" +%s)) / 86400))
  if nix build --no-link --impure --expr "
      let
        pkgs = import (builtins.fetchTree \"github:NixOS/nixpkgs/nixos-unstable\") {
          system = \"$system\";
          config.allowUnfree = true;
        };
      in
      pkgs.lib.getAttrFromPath (pkgs.lib.splitString \".\" \"$attr\") pkgs" >&2; then
    echo "release $name"
  else
    echo "held $name $days"
  fi
done
