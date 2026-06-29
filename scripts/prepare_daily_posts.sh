#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/prepare_daily_posts.sh [plan-output-path]

Behavior:
  1. Suggest 3 daily topics based on existing posts
  2. Write the suggested plan file
  3. Create 3 post drafts in _posts/
  4. Run post validation

If plan-output-path is omitted, a timestamped file is created under /tmp.
EOF
}

if [ "$#" -gt 1 ]; then
  usage
  exit 1
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
posts_dir="${POSTS_DIR:-${repo_root}/_posts}"
plan_path="${1:-}"

if [ -z "$plan_path" ]; then
  timestamp="$(TZ=Asia/Seoul date "+%Y%m%d-%H%M%S")"
  plan_path="/tmp/daily-posts-plan-${timestamp}.txt"
fi

mkdir -p "$(dirname "$plan_path")"
mkdir -p "$posts_dir"

suggest_output="$(mktemp /tmp/daily-suggest.XXXXXX)"
trap 'rm -f "$suggest_output"' EXIT

ruby "${repo_root}/scripts/suggest_daily_topics.rb" > "$suggest_output"

awk '
  found { print }
  /^Plan file lines:$/ { found = 1; next }
' "$suggest_output" > "$plan_path"

line_count="$(grep -cve '^[[:space:]]*$' "$plan_path" || true)"
if [ "$line_count" -ne 3 ]; then
  echo "expected 3 plan lines, found ${line_count}: ${plan_path}" >&2
  exit 1
fi

awk '
  /^Suggested daily topics:$/ { print; capture = 1; next }
  /^Plan file lines:$/ { capture = 0 }
  capture { print }
' "$suggest_output"
echo
echo "Plan file written: ${plan_path}"

POSTS_DIR="$posts_dir" "${repo_root}/scripts/new_daily_posts.sh" "$plan_path"
POSTS_DIR="$posts_dir" ruby "${repo_root}/scripts/check_posts.rb"

echo
echo "Daily preparation complete."
