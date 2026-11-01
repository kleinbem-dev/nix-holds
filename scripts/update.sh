#!/usr/bin/env bash
# Usage: scripts/update.sh FLAKE [--no-build] [--only a,b]
#
# NIX_HOLDS_ARGS: extra arguments for every nix eval and build (such as
# --override-input), split on spaces.
# After a lock update: finds which of FLAKE's watched packages
# (nixHoldsWatch.<system>, from lib.watch) fail, so they can be held.
# Evaluates each one on its own; builds those that evaluate but that no
# substituter has (unless --no-build). Prints "broken <name> <reason>" for
# each that fails and "ok <count>" at the end. --only checks just those
# names (the action re-checks its new holds with it).
set -uo pipefail

flake="$1"
shift
build=true only=""
while (($#)); do
  case "$1" in
    --no-build) build=false; shift ;;
    --only) only="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

# shellcheck disable=SC2206  # split on spaces on purpose
extra=(${NIX_HOLDS_ARGS:-})
system=$(nix eval --raw --impure --expr builtins.currentSystem)
watch="$flake#nixHoldsWatch.$system"
# shellcheck disable=SC2016  # a Nix expression
filter='ws: let only = builtins.filter (n: builtins.isString n && n != "") (builtins.split "," "'"$only"'"); in
  if only == [ ] then ws else builtins.intersectAttrs (builtins.listToAttrs (map (n: { name = n; value = null; }) only)) ws'

# The innermost error of evaluating NAME, the cause, as the reason for its
# hold (the outer ones are often a bare "error:").
reason() {
  nix eval "${extra[@]}" --raw "$watch.\"$1\".drvPath" 2>&1 >/dev/null | awk '
    /^[[:space:]]*error:[[:space:]]*[^[:space:]]/ { sub(/^[[:space:]]*error:[[:space:]]*/, ""); last = $0; inlist = 1; next }
    inlist && /^[[:space:]]*- / { sub(/^[[:space:]]*/, " "); last = last $0; next }
    { inlist = 0 }
    END { print last }' | sed -E 's| in /nix/store/[^ ]+||' | cut -c1-300
}

# name -> { drv, out } or null when it doesn't evaluate. tryEval catches
# throws (broken, unfree, insecure, removed aliases); other errors fail the
# whole evaluation, and then each name is evaluated on its own.
results=$(nix eval "${extra[@]}" --json "$watch" --apply "ws: builtins.mapAttrs (_: p:
  let r = builtins.tryEval (builtins.seq p.drvPath p.outPath); in
  if r.success then { drv = p.drvPath; out = r.value; } else null) (($filter) ws)" 2>/dev/null)
if [[ -z $results ]]; then
  names=$(nix eval "${extra[@]}" --json "$watch" --apply "ws: builtins.attrNames (($filter) ws)") || {
    echo "cannot evaluate $watch" >&2
    exit 1
  }
  results='{}'
  for name in $(jq -r '.[]' <<<"$names"); do
    one=$(nix eval "${extra[@]}" --json "$watch.\"$name\"" --apply 'p: { drv = p.drvPath; out = p.outPath; }' 2>/dev/null || echo null)
    results=$(jq --arg n "$name" --argjson v "$one" '.[$n] = $v' <<<"$results")
  done
fi

broken=()
while read -r name; do
  [[ -n $name ]] || continue
  broken+=("$name")
  echo "broken $name $(reason "$name")"
done < <(jq -r 'to_entries[] | select(.value == null) | .key' <<<"$results")

if $build; then
  mapfile -t drvs < <(jq -r '.[] | select(. != null) | .drv' <<<"$results")
  if ((${#drvs[@]})); then
    # What no substituter has: the watched derivations themselves among what
    # a build would build (their dependencies get built along the way).
    tobuild=$(nix build "${extra[@]}" --dry-run "${drvs[@]/%/^*}" 2>&1 | sed -n '/will be built:/,/will be fetched/p' | grep -oE '/nix/store/[^ ]+\.drv' | sort -u)
    mapfile -t mine < <(jq -r --arg b "$tobuild" '($b | split("\n")) as $set
      | to_entries[] | select(.value != null and (.value.drv | IN($set[]))) | .value.drv' <<<"$results")
    if ((${#mine[@]})); then
      nix build "${extra[@]}" --no-link --keep-going "${mine[@]/%/^*}" >&2 || true
      while read -r name out; do
        if ! nix path-info "$out" >/dev/null 2>&1; then
          broken+=("$name")
          echo "broken $name fails to build"
        fi
      done < <(jq -r --arg m "${mine[*]}" '($m | split(" ")) as $set
        | to_entries[] | select(.value != null and (.value.drv | IN($set[]))) | "\(.key) \(.value.out)"' <<<"$results")
    fi
  fi
fi

echo "ok $(($(jq 'length' <<<"$results") - ${#broken[@]}))"
