#!/usr/bin/env bash
# Usage: scripts/commit-signed.sh BRANCH HEADLINE PATH...
#
# Commits the current content of PATH... on top of BRANCH (an existing
# branch, such as a lock-update PR's) through GraphQL createCommitOnBranch, so
# GitHub signs the commit without key material in CI. Fails if BRANCH moved
# since it was read. Needs GH_TOKEN and GITHUB_REPOSITORY.
set -euo pipefail

branch="$1" headline="$2"
shift 2
repo="${GITHUB_REPOSITORY:?}"
head=$(gh api "repos/$repo/git/ref/heads/$branch" --jq .object.sha)

additions='[]'
for path in "$@"; do
  additions=$(jq --arg p "$path" --arg c "$(base64 -w0 "$path")" '. + [{path: $p, contents: $c}]' <<<"$additions")
done

jq -n \
  --arg repo "$repo" --arg branch "$branch" --arg sha "$head" --arg headline "$headline" \
  --argjson additions "$additions" \
  --arg query 'mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }' \
  '{query: $query, variables: {input: {
      branch: {repositoryNameWithOwner: $repo, branchName: $branch},
      message: {headline: $headline},
      expectedHeadOid: $sha,
      fileChanges: {additions: $additions}
  }}}' | gh api graphql --input - --jq .data.createCommitOnBranch.commit.oid
