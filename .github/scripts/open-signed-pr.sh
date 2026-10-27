#!/usr/bin/env bash
# Usage: scripts/open-signed-pr.sh BRANCH TITLE BODY [--draft] PATH...
#
# Commits the current content of PATH... (a missing PATH is deleted) to BRANCH,
# reset to main, through GraphQL createCommitOnBranch, so GitHub signs the
# commit and it satisfies the required_signatures ruleset without key material
# in CI. Then opens a PR for it with squash auto-merge, or a draft without
# auto-merge (--draft). Needs GH_TOKEN (the App token) and GITHUB_REPOSITORY.
set -euo pipefail

branch="$1" title="$2" body="$3"
shift 3
draft=false
if [[ ${1:-} == --draft ]]; then
  draft=true
  shift
fi
repo="${GITHUB_REPOSITORY:?}"

main_sha=$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)
if gh api "repos/$repo/git/ref/heads/$branch" >/dev/null 2>&1; then
  gh api -X PATCH "repos/$repo/git/refs/heads/$branch" -f sha="$main_sha" -F force=true >/dev/null
else
  gh api "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$main_sha" >/dev/null
fi

additions='[]' deletions='[]'
for path in "$@"; do
  if [[ -e $path ]]; then
    additions=$(jq --arg p "$path" --arg c "$(base64 -w0 "$path")" '. + [{path: $p, contents: $c}]' <<<"$additions")
  else
    deletions=$(jq --arg p "$path" '. + [{path: $p}]' <<<"$deletions")
  fi
done

jq -n \
  --arg repo "$repo" --arg branch "$branch" --arg sha "$main_sha" --arg headline "$title" \
  --argjson additions "$additions" --argjson deletions "$deletions" \
  --arg query 'mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }' \
  '{query: $query, variables: {input: {
      branch: {repositoryNameWithOwner: $repo, branchName: $branch},
      message: {headline: $headline},
      expectedHeadOid: $sha,
      fileChanges: {additions: $additions, deletions: $deletions}
  }}}' | gh api graphql --input - >/dev/null

# Resetting the branch makes it identical to main for an instant, and GitHub
# sometimes closes an open PR for it right then; reopen it instead.
state=$(gh pr list --head "$branch" --state all --limit 1 --json state --jq '.[0].state // empty')
if [[ $state == CLOSED ]]; then
  gh pr reopen "$branch"
elif [[ $state != OPEN ]]; then
  if $draft; then
    gh pr create --draft --title "$title" --body "$body" --head "$branch" --base main
  else
    gh pr create --title "$title" --body "$body" --head "$branch" --base main
  fi
fi
if ! $draft; then
  gh pr merge "$branch" --auto --squash
fi
