#!/usr/bin/env bash
# Usage: scripts/clone-holds.sh
#
# The update action's first step when the holds file is in another
# repository (HOLDS_REPO): clones it at the revision the flake's lock has for
# HOLDS_INPUT (the one the lock update was validated with) and exports,
# through GITHUB_ENV, NIX_DETOUR_HOLDS_CLONE (the clone) and
# NIX_DETOUR_OVERRIDE (the --override-input of HOLDS_INPUT with the clone),
# so every check, the first one included, sees those holds.
set -euo pipefail

[[ -n ${HOLDS_INPUT:-} ]] || { echo "holds-repo needs holds-input (its flake input here)" >&2; exit 1; }
# A misspelt input would leave every check on the locked holds (some Nix
# versions only warn about an unknown --override-input).
lock="${FLAKE:-.}/flake.lock"
# Nested paths (a/b) are walked through the lock, follows included.
# shellcheck disable=SC2016  # a jq program
node='. as $lock | def nodeof($segs): reduce $segs[] as $s ($lock.root // "root"; if . == null then null
  else ($lock.nodes[.].inputs[$s] // null) | if type == "array" then nodeof(.) else . end end);
  nodeof($i | split("/"))'
if [[ -f $lock ]] && ! jq -e --arg i "$HOLDS_INPUT" "$node != null" "$lock" >/dev/null; then
  echo "holds-input $HOLDS_INPUT is not an input of ${FLAKE:-.} (see its flake.lock)" >&2
  exit 1
fi
rev=""
if [[ -f $lock ]]; then
  # shellcheck disable=SC2016  # a jq program
  rev=$(jq -r --arg i "$HOLDS_INPUT" "$node"' as $n | .nodes[$n].locked.rev // empty' "$lock")
fi
clone="$RUNNER_TEMP/holds-repo"
rm -rf "$clone"
if [[ -d $HOLDS_REPO ]]; then
  # A local repository (for testing).
  git clone -q "$HOLDS_REPO" "$clone"
  [[ -z $rev ]] || git -C "$clone" checkout -q "$rev"
else
  GH_TOKEN="${HOLDS_TOKEN:-${GH_TOKEN:-}}" gh repo clone "$HOLDS_REPO" "$clone" -- --depth 1 -q
  if [[ -n $rev ]]; then
    git -C "$clone" fetch -q --depth 1 origin "$rev"
    git -C "$clone" checkout -q FETCH_HEAD
  fi
fi
{
  echo "NIX_DETOUR_HOLDS_CLONE=$clone"
  echo "NIX_DETOUR_OVERRIDE=--override-input $HOLDS_INPUT path:$clone"
} >>"$GITHUB_ENV"
