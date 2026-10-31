#!/usr/bin/env bash
# Usage: scripts/release-check.sh FLAKE HOLDS-FILE CHANNEL
#
# For each hold in HOLDS-FILE that FLAKE has a release check for
# (releaseChecks.<system>.<name>, from mkHolds), builds that check with the
# flake's nixpkgs set to CHANNEL. Prints "release <name>" for each that builds
# and "held <name> <days>" for the others.
set -uo pipefail

flake="$1" holds="$2" channel="$3"
system=$(nix eval --raw --impure --expr builtins.currentSystem)
today=$(date -u +%s)
checks=$(nix eval --json "$flake#releaseChecks.$system" --apply builtins.attrNames --override-input nixpkgs "$channel") || {
  echo "cannot evaluate $flake#releaseChecks.$system" >&2
  exit 1
}

mapfile -t names < <(jq -r 'keys[]' "$holds")
for name in "${names[@]}"; do
  if ! jq -e --arg n "$name" 'index($n)' <<<"$checks" >/dev/null; then
    echo "skipping $name: $flake has no release check for it on $system" >&2
    continue
  fi
  since=$(jq -r --arg n "$name" '.[$n].since' "$holds")
  days=$(((today - $(date -u -d "$since" +%s)) / 86400))
  if nix build --no-link "$flake#releaseChecks.$system.\"$name\"" --override-input nixpkgs "$channel" >&2; then
    echo "release $name"
  else
    echo "held $name $days"
  fi
done
