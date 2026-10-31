#!/usr/bin/env bash
# nix-holds: manage the holds file of a flake (held-packages.json).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nix-holds <command> [options]

  add NAME --reason TEXT [--link URL] [--from previous|stable|REV]
           [--release-when ATTR] [--tests a,b]
      Hold NAME. --from previous (the default) takes the nixpkgs your
      flake.lock had before its last change to that input, from git history.
  remove NAME
      Drop the hold of NAME.
  list
      Show every hold, where it comes from and how old it is.
  check [--flake REF] [--channel REF]
      Build what ends each hold (the flake's releaseChecks) from the newest
      nixpkgs and say which holds can go.

Options for every command:
  --file PATH    the holds file (default: held-packages.json)
  --lock PATH    the flake.lock to read (default: flake.lock)
  --input NAME   the nixpkgs input in that lock (default: nixpkgs)
EOF
}

die() {
  echo "nix-holds: $*" >&2
  exit 1
}

file=held-packages.json lock=flake.lock input=nixpkgs
from=previous reason="" link="" release_when="" tests="" flake=. channel=github:NixOS/nixpkgs/nixos-unstable
args=()
while (($#)); do
  case "$1" in
    --file) file="$2"; shift 2 ;;
    --lock) lock="$2"; shift 2 ;;
    --input) input="$2"; shift 2 ;;
    --from) from="$2"; shift 2 ;;
    --reason) reason="$2"; shift 2 ;;
    --link) link="$2"; shift 2 ;;
    --release-when) release_when="$2"; shift 2 ;;
    --tests) tests="$2"; shift 2 ;;
    --flake) flake="$2"; shift 2 ;;
    --channel) channel="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) args+=("$1"); shift ;;
  esac
done
((${#args[@]})) || { usage >&2; exit 1; }
command="${args[0]}"

holds() {
  if [[ -e $file ]]; then cat "$file"; else echo '{}'; fi
}

# Writes the holds from stdin, top-level keys sorted, entries as they are.
write_holds() {
  jq --indent 2 'to_entries | sort_by(.key) | from_entries' >"$file.new"
  mv "$file.new" "$file"
}

# Prints {rev, narHash} of $input in the lock JSON on stdin.
locked_nixpkgs() {
  jq -e --arg i "$input" '
    .nodes[.nodes.root.inputs[$i]
      | if type == "string" then . else error("input \($i) follows another input") end
    ].locked | {rev, narHash}' 2>/dev/null
}

# The nixpkgs before the last change of $input: the newest committed
# flake.lock whose rev differs from the current one.
previous_nixpkgs() {
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    die "--from previous reads flake.lock's git history; pass --from REV or stable instead"
  fi
  local current commit locked
  current=$(locked_nixpkgs <"$lock" | jq -r .rev) || die "no input $input in $lock"
  while read -r commit; do
    locked=$(git show "$commit:./$lock" 2>/dev/null | locked_nixpkgs) || continue
    if [[ $(jq -r .rev <<<"$locked") != "$current" ]]; then
      echo "$locked"
      return
    fi
  done < <(git log --format=%H -- "$lock")
  die "no earlier nixpkgs in the history of $lock"
}

case "$command" in
  add)
    name="${args[1]:-}"
    [[ -n $name ]] || die "add needs the name of the package"
    [[ -n $reason ]] || die "add needs --reason (why it is held)"
    case "$from" in
      stable) source='"stable"' ;;
      previous) source=$(previous_nixpkgs) ;;
      *)
        hash=$(nix flake prefetch --json "github:NixOS/nixpkgs/$from" | jq -r .hash) \
          || die "cannot fetch nixpkgs $from"
        source=$(jq -n --arg rev "$from" --arg h "$hash" '{rev: $rev, narHash: $h}')
        ;;
    esac
    holds | jq --arg n "$name" --argjson from "$source" --arg since "$(date -u +%F)" \
      --arg reason "$reason" --arg link "$link" --arg rw "$release_when" --arg tests "$tests" '
      .[$n] = ({from: $from, since: $since}
        + (if $rw == "" then {} else {releaseWhen: $rw} end)
        + {reason: $reason}
        + (if $link == "" then {} else {link: $link} end)
        + (if $tests == "" then {} else {tests: ($tests | split(","))} end))' | write_holds
    echo "holding $name from $(jq -r --arg n "$name" '.[$n].from | if type == "string" then . else .rev end' "$file")"
    ;;
  remove)
    name="${args[1]:-}"
    holds | jq -e --arg n "$name" 'has($n)' >/dev/null || die "$name is not held"
    holds | jq --arg n "$name" 'del(.[$n])' | write_holds
    echo "released $name"
    ;;
  list)
    today=$(date -u +%s)
    holds | jq -r 'to_entries[] | [.key, (.value.from | if type == "string" then . else .rev[0:12] end),
      .value.since, (.value.releaseWhen // "")] | @tsv' |
      while IFS=$'\t' read -r name src since rw; do
        days=$(((today - $(date -u -d "$since" +%s)) / 86400))
        printf '%-24s %-14s %s (%s days)%s\n' "$name" "$src" "$since" "$days" "${rw:+  until $rw builds}"
      done
    ;;
  check)
    @releaseCheck@ "$flake" "$file" "$channel"
    ;;
  *) die "unknown command $command (see --help)" ;;
esac
