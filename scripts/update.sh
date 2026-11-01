#!/usr/bin/env bash
# Usage: scripts/update.sh FLAKE [--no-build] [--only a,b]
#
# After a lock update: finds the packages FLAKE uses that fail, so they can
# be held. Two ways, each used when the flake has the output:
#
# - nixDetourWatch.<system> (lib.watch.packages/nixos): each package is
#   evaluated on its own; those that evaluate but that no substituter has
#   are built (unless --no-build).
# - nixDetourTargets.<system>.<name> = { target; pkgs; } (lib.watch.target):
#   each target (a host's toplevel) is evaluated; on failure, the package to
#   hold is the innermost derivation in the error's trace that is a
#   top-level attribute of pkgs and fails on its own there. One per target
#   and run: hold it and run again for the next.
#
# Prints "broken <name> <reason>" per package to hold, "unattributed
# <target> <reason>" for a target that fails without one, and "ok <system> <count>"
# for the watched packages that pass. --only limits the watched packages to
# those names. NIX_DETOUR_ARGS: extra arguments for every nix eval and build
# (such as --override-input), split on spaces. NIX_DETOUR_SYSTEMS: the
# systems to check, split on spaces (default: this one); evaluation works for
# any system, builds only for this one.
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

read -ra extra <<<"${NIX_DETOUR_ARGS:-}"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
native=$(nix eval --raw --impure --expr builtins.currentSystem)
read -ra systems <<<"${NIX_DETOUR_SYSTEMS:-}"
((${#systems[@]})) || systems=("$native")
# shellcheck disable=SC2016  # a Nix expression
filter='ws: let only = builtins.filter (n: builtins.isString n && n != "") (builtins.split "," "'"$only"'"); in
  if only == [ ] then ws else builtins.intersectAttrs (builtins.listToAttrs (map (n: { name = n; value = null; }) only)) ws'

# The innermost error in nix's stderr on stdin, the cause (the outer ones are
# often a bare "error:"), with a "- broken: ..." list after it.
innermost() {
  awk '
    /^[[:space:]]*error:[[:space:]]*[^[:space:]]/ { sub(/^[[:space:]]*error:[[:space:]]*/, ""); last = $0; inlist = 1; next }
    inlist && /^[[:space:]]*- / { sub(/^[[:space:]]*/, " "); last = last $0; next }
    { inlist = 0 }
    END { print last }' | sed -E 's| in /nix/store/[^ ]+||' | cut -c1-300
}

# Why evaluating watched package NAME fails.
reason() {
  nix eval "${extra[@]}" --raw "$watch.\"$1\".drvPath" 2>&1 >/dev/null | innermost
}

# Whether the flake has output $1 for this system (an output that fails to
# evaluate counts as there).
has_output() {
  local err
  err=$(nix eval "${extra[@]}" --raw "$flake#$1.$system" --apply 'x: "yes"' 2>&1 >/dev/null) && return 0
  ! grep -q 'does not provide attribute' <<<"$err"
}

# Checks one system; $system is the one.
check() {
  local system="$1" results broken watch targets target err chain name why list watchOut targetsOut
  results='{}' broken=()
  # The outputs were named nixHoldsWatch/nixHoldsTargets before nix-holds
  # became nix-detour; the old names still work.
  watchOut=nixDetourWatch targetsOut=nixDetourTargets
  if ! has_output nixDetourWatch && has_output nixHoldsWatch; then
    echo "nixHoldsWatch is now nixDetourWatch; rename the output" >&2
    watchOut=nixHoldsWatch
  fi
  if ! has_output nixDetourTargets && has_output nixHoldsTargets; then
    echo "nixHoldsTargets is now nixDetourTargets; rename the output" >&2
    targetsOut=nixHoldsTargets
  fi
  watch="$flake#$watchOut.$system"
  if has_output "$watchOut"; then
    # name -> { drv, out } or null when it doesn't evaluate. tryEval catches
    # throws (broken, unfree, insecure, removed aliases); other errors fail the
    # whole evaluation, and then each name is evaluated on its own.
    results=$(nix eval "${extra[@]}" --json "$watch" --apply "ws: builtins.mapAttrs (_: p:
      let r = builtins.tryEval (builtins.seq p.drvPath p.outPath); in
      if r.success then { drv = p.drvPath; out = r.value; } else null) (($filter) ws)" 2>/dev/null)
    if [[ -z $results ]]; then
      # A watch list that can't even be listed (say, a host's package list
      # names a removed attribute) is reported; the targets still run.
      names=$(nix eval "${extra[@]}" --json "$watch" --apply "ws: builtins.attrNames (($filter) ws)" 2>"$tmp/err") || {
        echo "unattributed $watchOut.$system $(innermost <"$tmp/err")"
        names='[]'
      }
      results='{}'
      mapfile -t list < <(jq -r '.[]' <<<"$names")
    for name in "${list[@]}"; do
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

    if $build && [[ $system == "$native" ]]; then
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
  fi

  if [[ -z $only ]] && has_output "$targetsOut"; then
    targets=$(nix eval "${extra[@]}" --json "$flake#$targetsOut.$system" --apply builtins.attrNames 2>"$tmp/err") || {
      echo "unattributed $targetsOut.$system $(innermost <"$tmp/err")"
      targets='[]'
    }
    mapfile -t list < <(jq -r '.[]' <<<"$targets")
    for target in "${list[@]}"; do
      err=$(nix eval "${extra[@]}" --show-trace --raw "$flake#$targetsOut.$system.\"$target\".target.drvPath" 2>&1 >/dev/null) && continue
      # The derivations in the trace, innermost first.
      chain=$(grep -oE "while evaluating derivation '[^']+'" <<<"$err" | cut -d"'" -f2 | tac | jq -Rsc 'split("\n") | map(select(. != ""))')
      # shellcheck disable=SC2016  # a Nix expression
      name=$(nix eval "${extra[@]}" --raw "$flake#$targetsOut.$system.\"$target\".pkgs" --apply "pkgs: let
          names = map (d: (builtins.parseDrvName d).name) (builtins.fromJSON ''$chain'');
          held = builtins.filter (n: pkgs ? \${n} && !(builtins.tryEval pkgs.\${n}.drvPath).success) names;
        in if held == [ ] then \"\" else builtins.head held" 2>/dev/null)
      why=$(innermost <<<"$err")
      if [[ -n $name ]]; then
        echo "broken $name $why (in $target)"
      else
        echo "unattributed $target $why"
      fi
    done
  fi

  echo "ok $system $(($(jq 'length' <<<"$results") - ${#broken[@]}))"
}

for system in "${systems[@]}"; do
  check "$system"
done
