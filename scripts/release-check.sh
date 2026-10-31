#!/usr/bin/env bash
# Usage: scripts/release-check.sh FLAKE CHANNEL
#
# Builds each of FLAKE's release checks (releaseChecks.<system>.<name>, from
# mkHolds) with the flake's nixpkgs set to CHANNEL. The holds, their names and
# dates, come from those checks, so they are the ones the flake uses. Prints
# "release <name>" for each that builds and "held <name> <days>" for the
# others (no days for a hold without `since`).
set -uo pipefail

flake="$1" channel="$2"
system=$(nix eval --raw --impure --expr builtins.currentSystem)
today=$(date -u +%s)
holds=$(nix eval --json "$flake#releaseChecks.$system" --override-input nixpkgs "$channel" \
  --apply 'builtins.mapAttrs (_: check: { since = check.nixHolds.since or null; })') || {
  echo "cannot evaluate $flake#releaseChecks.$system" >&2
  exit 1
}

mapfile -t names < <(jq -r 'keys[]' <<<"$holds")
for name in "${names[@]}"; do
  since=$(jq -r --arg n "$name" '.[$n].since // empty' <<<"$holds")
  days=""
  [[ -z $since ]] || days=$(((today - $(date -u -d "$since" +%s)) / 86400))
  if nix build --no-link "$flake#releaseChecks.$system.\"$name\"" --override-input nixpkgs "$channel" >&2; then
    echo "release $name"
  else
    echo "held $name${days:+ $days}"
  fi
done
