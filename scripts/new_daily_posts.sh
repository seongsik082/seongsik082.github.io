#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/new_daily_posts.sh path/to/daily-posts-plan.txt

Plan file format:
  title|slug|Tag1,Tag2|excerpt

Rules:
  - exactly 3 non-empty lines are required
  - lines starting with # are ignored
  - title, slug, and excerpt must not be empty

Example:
  JVM 스레드 덤프를 어디부터 읽어야 하는가|jvm-thread-dump-first-pass|Java,Performance|스레드 덤프는 장애 원인을 좁히는 가장 빠른 단서가 될 수 있습니다.
  Spring 트랜잭션 전파가 서비스 경계를 흐리는 순간|spring-transaction-propagation-service-boundary|Spring,Database|전파 옵션은 코드 재사용보다 장애 범위를 먼저 바꿉니다.
  REST API에서 202 Accepted를 써야 하는 작업과 아닌 작업|rest-api-202-accepted-usage|REST API,HTTP|비동기 작업 응답은 상태 코드 하나로 끝나지 않고 조회 방식까지 함께 설계해야 합니다.
EOF
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

if [ "$#" -ne 1 ]; then
  usage
  exit 1
fi

plan_file="$1"
posts_dir="${POSTS_DIR:-_posts}"

if [ ! -f "$plan_file" ]; then
  echo "plan file not found: $plan_file" >&2
  exit 1
fi

entries=()
while IFS= read -r line || [ -n "$line" ]; do
  stripped="$(trim "$line")"
  [ -z "$stripped" ] && continue
  [[ "$stripped" == \#* ]] && continue

  IFS='|' read -r raw_title raw_slug raw_tags raw_excerpt extra <<< "$stripped"
  if [ -n "${extra:-}" ]; then
    echo "invalid plan line (too many fields): $line" >&2
    exit 1
  fi

  title="$(trim "${raw_title:-}")"
  slug="$(trim "${raw_slug:-}")"
  tags="$(trim "${raw_tags:-}")"
  excerpt="$(trim "${raw_excerpt:-}")"

  if [ -z "$title" ] || [ -z "$slug" ] || [ -z "$excerpt" ]; then
    echo "title, slug, and excerpt are required: $line" >&2
    exit 1
  fi

  entries+=("${title}"$'\t'"${slug}"$'\t'"${tags}"$'\t'"${excerpt}")
done < "$plan_file"

if [ "${#entries[@]}" -ne 3 ]; then
  echo "plan file must contain exactly 3 post entries, found ${#entries[@]}" >&2
  exit 1
fi

mkdir -p "$posts_dir"
tmpdir="$(mktemp -d /tmp/daily-posts.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

offsets=(7 6 5)

for idx in "${!entries[@]}"; do
  IFS=$'\t' read -r title slug tags excerpt <<< "${entries[$idx]}"
  POSTS_DIR="$tmpdir" POST_OFFSET_MINUTES="${offsets[$idx]}" scripts/new_post.sh "$title" "$slug" "$tags" "$excerpt"
done

for generated in "$tmpdir"/*.md; do
  target="${posts_dir}/$(basename "$generated")"
  if [ -e "$target" ]; then
    echo "post already exists: $target" >&2
    exit 1
  fi
done

mv "$tmpdir"/*.md "$posts_dir"/

echo "created 3 posts in ${posts_dir}:"
for generated in "$posts_dir"/*.md; do
  :
done

for idx in "${!entries[@]}"; do
  IFS=$'\t' read -r _ slug _ _ <<< "${entries[$idx]}"
  if date -v-"${offsets[$idx]}"M "+%Y-%m-%d" >/dev/null 2>&1; then
    post_date="$(TZ=Asia/Seoul date -v-"${offsets[$idx]}"M "+%Y-%m-%d")"
  else
    post_date="$(TZ=Asia/Seoul date -d "${offsets[$idx]} minutes ago" "+%Y-%m-%d")"
  fi
  echo "- ${posts_dir}/${post_date}-${slug}.md"
done
