#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
filter="$repo_root/.githooks/git-crypt-filter"
worktree="$repo_root/.worktrees/test-git-crypt-filter"

cleanup() {
  git -C "$repo_root" worktree remove --force "$worktree" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup

git -C "$repo_root" \
  -c "filter.git-crypt.smudge=$filter smudge" \
  -c "filter.git-crypt.clean=$filter clean" \
  -c filter.git-crypt.required=true \
  worktree add --detach --no-checkout "$worktree" HEAD

git -C "$worktree" \
  -c "filter.git-crypt.smudge=$filter smudge" \
  -c "filter.git-crypt.clean=$filter clean" \
  -c filter.git-crypt.required=true \
  checkout --force HEAD

if ! sed -n '1p' "$worktree/secrets.yaml" | grep -qx 'cluster:'; then
  echo "expected linked worktree checkout to decrypt secrets.yaml" >&2
  exit 1
fi

git -C "$worktree" \
  -c "filter.git-crypt.smudge=$filter smudge" \
  -c "filter.git-crypt.clean=$filter clean" \
  -c filter.git-crypt.required=true \
  diff --quiet
