#!/usr/bin/env bash
# nix-holds pr: manage the PRs file of a flake (nixpkgs-prs.json).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nix-holds pr <command> [options]

  add NAME --pr NUMBER --repo OWNER/REPO --attrs a,b [--rev SHA]
           [--scope c,d] [--module NAME=PATH]...
      Add the packages `attrs` of nixpkgs PR NUMBER, whose branch is in
      OWNER/REPO. --rev pins it right away. --scope names packages of the
      PR the attributes need but that stay unexported; --module adds a
      NixOS module of the PR (a path in the PR's tree).
  pin NAME SHA
      Pin NAME to commit SHA (all 40 characters) of its repository.
  remove NAME
      Drop NAME.
  list
      Show every entry, its PR and where it is pinned.
  eval NAME [--flake REF]
      Evaluate NAME's packages (the flake's nixpkgsPrs) and print their
      derivations.
  merged [--flake REF]
      Say which entries nixpkgs has in the same or a newer version: they
      can go.

Options for every command:
  --file PATH    the PRs file (default: nixpkgs-prs.json)
EOF
}

die() {
  echo "nix-holds pr: $*" >&2
  exit 1
}

file=nixpkgs-prs.json flake=. pr="" repo="" attrs="" rev="" scope=""
modules=()
args=()
need() {
  (($# >= 2)) || die "$1 needs a value"
}
while (($#)); do
  case "$1" in
    --file) need "$@"; file="$2"; shift 2 ;;
    --flake) need "$@"; flake="$2"; shift 2 ;;
    --pr) need "$@"; pr="$2"; shift 2 ;;
    --repo) need "$@"; repo="$2"; shift 2 ;;
    --attrs) need "$@"; attrs="$2"; shift 2 ;;
    --rev) need "$@"; rev="$2"; shift 2 ;;
    --scope) need "$@"; scope="$2"; shift 2 ;;
    --module) need "$@"; modules+=("$2"); shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) args+=("$1"); shift ;;
  esac
done
((${#args[@]})) || { usage >&2; exit 1; }
command="${args[0]}"
name="${args[1]:-}"

entries() {
  if [[ -e $file ]]; then
    jq . "$file" || die "$file is not valid JSON"
  else
    echo '{}'
  fi
}

# Writes the entries from stdin, top-level keys sorted, entries as they are.
# Empty input (a failed jq before it) leaves the file as it is.
write_entries() {
  local new
  new=$(jq --indent 2 'to_entries | sort_by(.key) | from_entries') && [[ -n $new ]] \
    || die "cannot update $file (is it valid JSON?)"
  printf '%s\n' "$new" >"$file"
}

need_entry() {
  [[ -n $name ]] || die "$command needs the name of the entry"
  entries | jq -e --arg n "$name" 'has($n)' >/dev/null || die "$file has no entry $name"
}

pin() {
  [[ $rev =~ ^[0-9a-f]{40}$ ]] || die "the commit must be a full 40-character SHA"
  local source hash
  source=$(entries | jq -r --arg n "$name" '.[$n] | "github:\(.owner)/\(.repo)"')
  hash=$(nix flake prefetch --json "$source/$rev" | jq -r .hash) || die "cannot fetch $source/$rev"
  entries | jq --arg n "$name" --arg rev "$rev" --arg h "$hash" \
    '.[$n].rev = $rev | .[$n].narHash = $h' | write_entries
  echo "$name pinned to $rev ($hash)"
}

system() {
  nix eval --raw --impure --expr builtins.currentSystem
}

case "$command" in
  add)
    [[ -n $name ]] || die "add needs the name of the entry"
    [[ $pr =~ ^[0-9]+$ ]] || die "add needs --pr (the nixpkgs PR number)"
    [[ $repo == */* ]] || die "add needs --repo OWNER/REPO (where the PR's branch is)"
    [[ -n $attrs ]] || die "add needs --attrs (the packages to take from the PR)"
    modules_json='{}'
    for module in "${modules[@]}"; do
      [[ $module == ?*=?* ]] || die "--module needs NAME=PATH"
      modules_json=$(jq --arg n "${module%%=*}" --arg p "${module#*=}" '.[$n] = $p' <<<"$modules_json")
    done
    entries | jq --arg n "$name" --argjson pr "$pr" --arg owner "${repo%%/*}" --arg repo "${repo#*/}" \
      --arg attrs "$attrs" --arg scope "$scope" --argjson modules "$modules_json" '
      .[$n] = ({pr: $pr, owner: $owner, repo: $repo, rev: "", narHash: "", attrs: ($attrs | split(","))}
        + (if $scope == "" then {} else {scope: ($scope | split(","))} end)
        + (if $modules == {} then {} else {modules: $modules} end))' | write_entries
    if [[ -n $rev ]]; then
      pin
    else
      echo "added $name; pin it with: nix-holds pr pin $name SHA"
    fi
    ;;
  pin)
    need_entry
    rev="${args[2]:-}"
    pin
    ;;
  remove)
    need_entry
    entries | jq --arg n "$name" 'del(.[$n])' | write_entries
    echo "removed $name"
    ;;
  list)
    entries | jq -r 'to_entries[] | [.key, "#\(.value.pr)",
      (if .value.rev == "" then "not pinned" else .value.rev[0:12] end),
      (.value.attrs | join(","))] | join("\u001f")' |
      while IFS=$'\x1f' read -r n p r a; do
        printf '%-24s %-8s %-12s %s\n' "$n" "$p" "$r" "$a"
      done
    ;;
  eval)
    need_entry
    nix eval --json "$flake#nixpkgsPrs.$(system).\"$name\".packages" \
      --apply 'builtins.mapAttrs (_: p: p.drvPath)' | jq -r 'to_entries[] | "\(.key) \(.value)"'
    ;;
  merged)
    merged=$(nix eval --json "$flake#nixpkgsPrs.$(system)" --apply 'builtins.mapAttrs (_: c: c.merged)') \
      || die "cannot evaluate $flake#nixpkgsPrs"
    jq -r 'to_entries[] | "\(if .value then "merged" else "open" end) \(.key)"' <<<"$merged"
    ;;
  *) die "unknown command $command (see --help)" ;;
esac
