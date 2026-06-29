#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/new_post.sh "제목" "english-slug" "Tag1,Tag2" "요약"

Example:
  scripts/new_post.sh \
    "트랜잭션 경계가 서비스 설계에 주는 영향" \
    "transaction-boundary-service-design" \
    "Spring,Database" \
    "트랜잭션 경계는 코드 구조와 장애 범위를 함께 바꿉니다."
EOF
}

if [ "$#" -ne 4 ]; then
  usage
  exit 1
fi

title="$1"
slug="$2"
raw_tags="$3"
excerpt="$4"

if [[ ! "$slug" =~ ^[a-z0-9-]+$ ]]; then
  echo "slug must use lowercase letters, numbers, and hyphens only." >&2
  exit 1
fi

posts_dir="${POSTS_DIR:-_posts}"

mkdir -p "$posts_dir"

if date -v-5M "+%Y-%m-%d %H:%M:%S %z" >/dev/null 2>&1; then
  post_datetime="$(TZ=Asia/Seoul date -v-5M "+%Y-%m-%d %H:%M:%S %z")"
  post_date="$(TZ=Asia/Seoul date -v-5M "+%Y-%m-%d")"
else
  post_datetime="$(TZ=Asia/Seoul date -d '5 minutes ago' "+%Y-%m-%d %H:%M:%S %z")"
  post_date="$(TZ=Asia/Seoul date -d '5 minutes ago' "+%Y-%m-%d")"
fi

trimmed_tags="$(printf '%s' "$raw_tags" | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/^,*//; s/,*$//')"
if [ -z "$trimmed_tags" ]; then
  trimmed_tags="Backend"
fi

if [[ ",$trimmed_tags," != *",Backend,"* ]]; then
  trimmed_tags="${trimmed_tags},Backend"
fi

tags_yaml="$(printf '%s' "$trimmed_tags" | sed 's/,/, /g')"
file_path="${posts_dir}/${post_date}-${slug}.md"

if [ -e "$file_path" ]; then
  echo "post already exists: $file_path" >&2
  exit 1
fi

cat >"$file_path" <<EOF
---
title: "${title}"
date: ${post_datetime}
tags: [${tags_yaml}]
excerpt: "${excerpt}"
---

## 문제 상황

이 주제가 실무에서 어떤 순간에 문제로 드러나는지부터 적습니다.
장애, 성능 저하, 코드 리뷰 논쟁, 운영 중 혼란 같은 실제 상황으로 시작합니다.

## 핵심 개념

용어를 길게 늘어놓기보다 지금 글에서 꼭 알아야 하는 원리만 설명합니다.
어려운 용어가 나오면 한 문장으로 짧게 풀어쓴 뒤 본론으로 돌아갑니다.

## 코드로 보기

\`\`\`java
// 여기에 핵심 예시를 넣습니다.
\`\`\`

## 자주 하는 실수

- 문제가 잘 안 드러나는 이유
- 로컬에서는 괜찮았는데 운영에서 터지는 이유
- 적용 범위를 너무 넓게 잡거나 좁게 잡는 실수

## 언제 쓰면 좋은가

- 어떤 조건이면 적용할지
- 어떤 상황이면 피할지
- 대체안이 더 나은 경우는 언제인지

## 운영에서 볼 것

- 어떤 로그를 먼저 볼지
- 어떤 메트릭을 확인할지
- 장애 시 어디부터 의심할지

## 정리

핵심 판단 기준을 3~5줄로 다시 정리합니다.

## 참고한 자료

- 공식 문서 링크
- 벤더 문서 또는 RFC 링크
EOF

echo "created: $file_path"
