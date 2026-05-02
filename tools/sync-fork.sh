#!/bin/bash
# sync-fork.sh — Sync this fork with upstream while preserving app commits
#
# Usage: tools/sync-fork.sh [--dry-run]
#
# What it does:
#   1. Fetches upstream/main
#   2. Records all app commits (everything after the URL-replacement commit)
#   3. Resets main to upstream/main
#   4. Applies deterministic URL replacement (community-scripts → steveonjava)
#   5. Cherry-picks all app commits on top (conflict-free since they only add files)
#   6. Force-pushes to origin
#
# Prerequisites:
#   - Remote 'upstream' pointing to community-scripts/ProxmoxVE
#   - Clean working tree (no uncommitted changes)
#   - App commits must NOT modify upstream files (only add new files)

set -euo pipefail

FORK_OWNER="steveonjava"
FORK_REPO="ProxmoxVE"
UPSTREAM_OWNER="community-scripts"
URL_COMMIT_MSG="chore: configure fork URLs for ${FORK_OWNER}/${FORK_REPO}"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "[DRY RUN] No changes will be made"
fi

cd "$(git rev-parse --show-toplevel)"

# Safety checks
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: Working tree is not clean. Commit or stash changes first."
    exit 1
fi

if ! git remote get-url upstream &>/dev/null; then
    echo "ERROR: No 'upstream' remote. Add it with:"
    echo "  git remote add upstream https://github.com/${UPSTREAM_OWNER}/${FORK_REPO}.git"
    exit 1
fi

echo "==> Fetching upstream..."
git fetch upstream

# Find the URL-replacement commit (identifies where app commits start)
URL_COMMIT=$(git log --oneline --all --grep="$URL_COMMIT_MSG" --format="%H" | head -1)
if [ -z "$URL_COMMIT" ]; then
    echo "ERROR: Cannot find URL-replacement commit. Expected message: $URL_COMMIT_MSG"
    exit 1
fi

# Collect app commits (everything after URL commit, oldest first)
APP_COMMITS=$(git rev-list --reverse "$URL_COMMIT"..HEAD)
APP_COUNT=$(echo "$APP_COMMITS" | grep -c . || echo 0)

echo "==> Found $APP_COUNT app commits to replay"
echo "==> Current upstream/main: $(git log --oneline -1 upstream/main)"

if $DRY_RUN; then
    echo ""
    echo "[DRY RUN] Would:"
    echo "  1. Reset main to upstream/main"
    echo "  2. Apply URL replacement (${UPSTREAM_OWNER} → ${FORK_OWNER})"
    echo "  3. Cherry-pick $APP_COUNT commits"
    echo "  4. Force push to origin/main"
    echo ""
    echo "App commits that would be replayed:"
    for h in $APP_COMMITS; do
        echo "  $(git log --oneline -1 "$h")"
    done
    exit 0
fi

# Save this script before reset (it gets wiped when resetting to upstream)
SELF_SCRIPT=$(cat tools/sync-fork.sh 2>/dev/null || true)

# Reset to upstream
echo "==> Resetting main to upstream/main..."
git checkout -B main upstream/main

# Apply URL replacement
echo "==> Applying URL replacement..."
find ct/ install/ misc/ frontend/ tools/ -type f \( -name "*.sh" -o -name "*.func" -o -name "*.json" \) 2>/dev/null | while read -r f; do
    sed -i "s|${UPSTREAM_OWNER}/${FORK_REPO}|${FORK_OWNER}/${FORK_REPO}|g" "$f"
done

# Restore this script
mkdir -p tools
echo "$SELF_SCRIPT" > tools/sync-fork.sh
chmod +x tools/sync-fork.sh

# Commit URL changes
git add -A
git commit -m "$URL_COMMIT_MSG"
echo "==> URL replacement committed"

# Cherry-pick app commits
echo "==> Replaying $APP_COUNT app commits..."
APPLIED=0
FAILED=0

# File patterns that identify app-specific files
APP_RE="hermesagent|hermes-agent|jrivermediacenter|jriver-media-center|protonmail-bridge|protonmailbridge|jriver\.sh|jriver-install|jriver\.json|ct/headers/jriver$|sync-fork"

for HASH in $APP_COMMITS; do
    SHORT=$(git log --oneline -1 "$HASH" | cut -c1-72)
    if git cherry-pick "$HASH" --no-verify 2>/dev/null; then
        APPLIED=$((APPLIED + 1))
        echo "  [$APPLIED/$APP_COUNT] $SHORT"
    else
        # Conflict — attempt auto-resolution
        echo "  [$((APPLIED + 1))/$APP_COUNT] CONFLICT: $SHORT"
        git cherry-pick --abort 2>/dev/null || true

        # Manual extract: get app files from the commit
        APP_FILES=$(git diff-tree --no-commit-id --name-only -r "$HASH" | grep -E "$APP_RE" || true)

        if [ -n "$APP_FILES" ]; then
            ORIG_AUTHOR=$(git log --format="%an <%ae>" -1 "$HASH")
            ORIG_DATE=$(git log --format="%aI" -1 "$HASH")
            ORIG_MSG=$(git log --format="%B" -1 "$HASH")
            HAVE_CHANGES=false

            while IFS= read -r f; do
                if git cat-file -e "$HASH:$f" 2>/dev/null; then
                    mkdir -p "$(dirname "$f")"
                    git show "$HASH:$f" > "$f"
                    git add -f "$f"
                    HAVE_CHANGES=true
                elif [ -f "$f" ]; then
                    git rm -f "$f" 2>/dev/null || true
                    HAVE_CHANGES=true
                fi
            done <<< "$APP_FILES"

            if $HAVE_CHANGES && ! git diff --cached --quiet 2>/dev/null; then
                git commit -m "$ORIG_MSG" --author="$ORIG_AUTHOR" --date="$ORIG_DATE" --no-verify
                APPLIED=$((APPLIED + 1))
                echo "    -> Resolved (manual extract)"
            else
                echo "    -> Skipped (no app changes)"
                git reset HEAD 2>/dev/null || true
                FAILED=$((FAILED + 1))
            fi
        else
            echo "    -> Skipped (no app files)"
            FAILED=$((FAILED + 1))
        fi
    fi
done

echo ""
echo "=== Sync complete ==="
echo "Applied: $APPLIED | Failed: $FAILED | Total: $APP_COUNT"
echo "Behind upstream: $(git log --oneline HEAD..upstream/main | wc -l)"
echo ""

# Push
echo "==> Pushing to origin (force-with-lease)..."
git push --force-with-lease origin main

echo ""
echo "Done! Fork is synced with upstream."
echo "Verify at: https://github.com/${FORK_OWNER}/${FORK_REPO}"
