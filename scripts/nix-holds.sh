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
      Build what ends each hold (the flake's releaseChecks, with the holds
      its mkHolds reads) from the newest nixpkgs; say which holds can go.
  pr ...
      Packages from open nixpkgs PRs (see nix-holds pr --help).

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

if [[ ${1:-} == pr ]]; then
  shift
  exec @prs@ "$@"
fi

file=held-packages.json lock=flake.lock input=nixpkgs
from=previous reason="" link="" release_when="" tests="" flake=. channel=github:NixOS/nixpkgs/nixos-unstable
args=()
# The value of option $1, or an error when it has none.
need() {
  (($# >= 2)) || die "$1 needs a value"
}
while (($#)); do
  case "$1" in
    --file) need "$@"; file="$2"; shift 2 ;;
    --lock) need "$@"; lock="$2"; shift 2 ;;
    --input) need "$@"; input="$2"; shift 2 ;;
    --from) need "$@"; from="$2"; shift 2 ;;
    --reason) need "$@"; reason="$2"; shift 2 ;;
    --link) need "$@"; link="$2"; shift 2 ;;
    --release-when) need "$@"; release_when="$2"; shift 2 ;;
    --tests) need "$@"; tests="$2"; shift 2 ;;
    --flake) need "$@"; flake="$2"; shift 2 ;;
    --channel) need "$@"; channel="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) args+=("$1"); shift ;;
  esac
done
((${#args[@]})) || { usage >&2; exit 1; }
command="${args[0]}"

holds() {
  if [[ -e $file ]]; then
    jq . "$file" || die "$file is not valid JSON"
  else
    echo '{}'
  fi
}

# Writes the holds from stdin, top-level keys sorted, entries as they are.
# Empty input (a failed jq before it) leaves the file as it is.
write_holds() {
  local new
  new=$(jq --indent 2 'to_entries | sort_by(.key) | from_entries') && [[ -n $new ]] \
    || die "cannot update $file (is it valid JSON?)"
  printf '%s\n' "$new" >"$file"
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
      (.value.since // ""), (.value.releaseWhen // "")] | join("\u001f")' |
      # \x1f, not a tab: read merges runs of whitespace, so an empty field
      # would shift the ones after it.
      while IFS=$'\x1f' read -r name src since rw; do
        age=""
        [[ -z $since ]] || age="$since ($(((today - $(date -u -d "$since" +%s)) / 86400)) days)"
        printf '%-24s %-14s %s%s\n' "$name" "$src" "${age:-no date}" "${rw:+  until $rw builds}"
      done
    ;;
  check)
    @releaseCheck@ "$flake" "$channel"
    ;;
  *) die "unknown command $command (see --help)" ;;
esac
