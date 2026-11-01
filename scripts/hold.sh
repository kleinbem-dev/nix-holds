#!/usr/bin/env bash
# Usage: scripts/hold.sh RESULTS
#
# The update action's second step. RESULTS is update.sh's output for the
# lock update. Holds each broken package on the nixpkgs of BASE's flake.lock
# and runs update.sh again: a package that still fails while held (or was
# held already) can't be fixed by a hold; a package found only now (the next
# failure of a target) is held in the next round, up to 5 rounds. With
# HOLDS_REPO, the holds file is in that repository: clone-holds.sh cloned it
# and points the checks at the clone, and commit mode opens a PR there.
# Without the holds file nothing can be checked: one round, unchecked.
#
# Environment: FLAKE, HOLDS, INPUT, BASE, MODE (commit|report), BRANCH,
# BUILD (true|false), NIX_DETOUR_ARGS, GH_TOKEN, HOLDS_REPO, HOLDS_INPUT,
# HOLDS_TOKEN; RUNNER_TEMP, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY and
# GITHUB_REPOSITORY as on GitHub.
set -euo pipefail

here=$(dirname "$(realpath "$0")")
results="$1"
cli=(nix run "path:$here/.." --)
args=()
[[ $BUILD == true ]] || args+=(--no-build)

git fetch --depth 1 origin "$BASE" 2>/dev/null
previous=$(git show FETCH_HEAD:flake.lock | jq -r --arg i "$INPUT" '.nodes[.nodes.root.inputs[$i]].locked.rev')

all="$RUNNER_TEMP/all.txt"
cp "$results" "$all"
# The reason update.sh gave for NAME the first time.
reason() {
  awk -v n="$1" '$1 == "broken" && $2 == n {$1 = $2 = ""; sub(/^ +/, ""); print; exit}' "$all"
}
has() {
  local name="$1"
  shift
  printf '%s\n' "$@" | grep -qxF -- "$name"
}

holds_repo="${HOLDS_REPO:-}"
if [[ -n $holds_repo ]]; then
  # Cloned by clone-holds.sh, which also points every check at the clone.
  clone="${NIX_DETOUR_HOLDS_CLONE:?run clone-holds.sh first}"
  holds_file="$HOLDS"
  [[ -z $holds_file ]] || HOLDS="$clone/$holds_file"
fi

held=() failed=() unchecked=()
checked=false
if [[ -e $HOLDS ]]; then
  checked=true
  cp "$HOLDS" "$RUNNER_TEMP/holds.before"
fi

round="$results"
for n in 1 2 3 4 5 6; do
  mapfile -t names < <(awk '$1 == "broken" {print $2}' "$round" | sort -u)
  new=()
  for name in "${names[@]}"; do
    if has "$name" "${failed[@]}"; then
      continue
    elif has "$name" "${held[@]}"; then
      # Held in this run and still failing.
      failed+=("$name")
      mapfile -t held < <(printf '%s\n' "${held[@]}" | grep -vxF -- "$name" || true)
      "${cli[@]}" remove "$name" --file "$HOLDS"
    elif $checked && jq -e --arg n "$name" 'has($n)' "$RUNNER_TEMP/holds.before" >/dev/null; then
      failed+=("$name")
    else
      new+=("$name")
    fi
  done
  ((${#new[@]})) || break
  if ! $checked; then
    unchecked=("${new[@]}")
    break
  fi
  if ((n == 6)); then
    unchecked=("${new[@]}")
    break
  fi
  for name in "${new[@]}"; do
    "${cli[@]}" add "$name" --file "$HOLDS" --from "$previous" \
      --reason "Broken by the lock update: $(reason "$name")"
    held+=("$name")
  done
  round="$RUNNER_TEMP/round$n.txt"
  # A command substitution, so a failing run fails the step instead of
  # passing for "nothing fails any more".
  output=$("$here/update.sh" "$FLAKE" "${args[@]}")
  printf '%s\n' "$output" | tee "$round" >>"$all"
done
mapfile -t unattributed < <(awk '$1 == "unattributed" {print $2}' "$round" | sort -u)


line() {
  echo "- \`$1\`: $(reason "$1")"
}
{
  if ((${#held[@]})); then
    if [[ $MODE == commit ]]; then
      echo "Held on nixpkgs ${previous:0:12}, the one before this update:"
    else
      echo "To hold on nixpkgs ${previous:0:12} (they work there):"
    fi
    echo
    for name in "${held[@]}"; do line "$name"; done
    echo
  fi
  if ((${#unchecked[@]})); then
    if $checked; then
      echo "To hold, not checked yet (more than 5 rounds):"
    else
      echo "To hold on nixpkgs ${previous:0:12} (not checked: no holds file at $HOLDS):"
    fi
    echo
    for name in "${unchecked[@]}"; do line "$name"; done
    echo
  fi
  if ((${#failed[@]})); then
    echo "Still fail when held (on nixpkgs ${previous:0:12}, or held already), so a hold doesn't help:"
    echo
    for name in "${failed[@]}"; do line "$name"; done
    echo
  fi
  if ((${#unattributed[@]})); then
    echo "Fail, but no package to hold was found in the error:"
    echo
    for target in "${unattributed[@]}"; do
      echo "- \`$target\`: $(awk -v n="$target" '$1 == "unattributed" && $2 == n {$1 = $2 = ""; sub(/^ +/, ""); print; exit}' "$round")"
    done
    echo
  fi
  ((${#held[@]} + ${#unchecked[@]} + ${#failed[@]} + ${#unattributed[@]})) || echo "Nothing fails."
} >"$RUNNER_TEMP/report.md"
cat "$RUNNER_TEMP/report.md" >>"$GITHUB_STEP_SUMMARY"

if $checked; then
  if [[ $MODE == commit ]] && ((${#held[@]})); then
    if [[ -n $holds_repo ]]; then
      # Only the new holds, on the holds file as it is now: changes merged
      # there during the checks stay.
      # A failed read stops here: committing over a file we couldn't read
      # would drop its holds.
      if [[ -d $holds_repo ]]; then
        current=$(git -C "$holds_repo" show "HEAD:$holds_file")
      else
        current=$(GH_TOKEN="${HOLDS_TOKEN:-${GH_TOKEN:-}}" gh api "repos/$holds_repo/contents/$holds_file" \
          -H "Accept: application/vnd.github.raw")
      fi
      jq -e 'type == "object"' <<<"$current" >/dev/null || { echo "$holds_repo: $holds_file is not a JSON object" >&2; exit 1; }
      jq --indent 2 --argjson current "$current" \
        '$current + with_entries(select(.key | IN($ARGS.positional[]))) | to_entries | sort_by(.key) | from_entries' \
        "$HOLDS" --args "${held[@]}" </dev/null >"$HOLDS.new"
      mv "$HOLDS.new" "$HOLDS"
      body="$(cat "$RUNNER_TEMP/report.md")

Found by the nix-detour update action on ${GITHUB_REPOSITORY:-the lock update}."
      (cd "$clone" && GITHUB_REPOSITORY="$holds_repo" GH_TOKEN="${HOLDS_TOKEN:-${GH_TOKEN:-}}" \
        "$here/open-signed-pr.sh" nix-detour/holds "chore: hold ${held[*]}" "$body" "$holds_file")
    else
      "$here/commit-signed.sh" "$BRANCH" "chore: hold ${held[*]}" "$HOLDS"
    fi
  else
    cp "$RUNNER_TEMP/holds.before" "$HOLDS"
  fi
fi
{
  # In report mode, "held" means "to hold".
  if [[ $MODE == commit ]]; then echo "held=${held[*]}"; else echo "held=$(echo "${held[*]} ${unchecked[*]}" | xargs)"; fi
  echo "failed=$(echo "${failed[*]} ${unattributed[*]}" | xargs)"
  echo "report<<NIX_DETOUR_REPORT"
  cat "$RUNNER_TEMP/report.md"
  echo "NIX_DETOUR_REPORT"
} >>"$GITHUB_OUTPUT"
