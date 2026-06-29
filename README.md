# 김성식 기술 블로그

Java, Spring, Database, API, 운영 이슈를 백엔드 개발자 관점에서 정리하는 GitHub Pages + Jekyll 블로그입니다.

## 블로그 방향

이 저장소는 단순한 포트폴리오 페이지보다, 백엔드 개발자가 실제로 운영과 트러블슈팅을 기록하는 블로그를 목표로 합니다.
글은 가능하면 다음 흐름으로 씁니다.

1. 왜 이 문제가 운영에서 보이는가
2. 핵심 원리가 무엇인가
3. 어떤 코드나 설정이 기준이 되는가
4. 언제 적용하고 언제 피해야 하는가
5. 어떤 로그와 지표를 먼저 볼 것인가

## 주요 파일

- `_posts/`: 날짜별 기술 포스트
- `index.md`: 첫 화면
- `archive.md`: 전체 글 목록과 필터
- `about.md`: 블로그 소개
- `projects.md`: 프로젝트 방향과 정리 기준
- `_layouts/`, `_includes/`: 공통 레이아웃
- `assets/css/style.css`: 전체 스타일
- `_config.yml`: 사이트 메타데이터

## 로컬에서 실행하기

GitHub Docs는 GitHub Pages 사이트를 로컬에서 테스트할 때 Bundler와 `github-pages` gem 사용을 권장합니다.
이 저장소도 그 흐름에 맞춰 `Gemfile`을 포함합니다.

1. Ruby와 Bundler를 설치합니다.
   가능하면 `.ruby-version`에 맞춰 Ruby `3.2` 계열을 사용하는 편이 안전합니다.
2. 저장소 루트에서 의존성을 설치합니다.

```bash
bundle install
```

3. 로컬 서버를 실행합니다.

```bash
bundle exec jekyll serve --baseurl=""
```

4. 브라우저에서 `http://127.0.0.1:4000`을 엽니다.

Ruby 3 계열에서 `webrick` 관련 오류가 나는 경우가 있어 `Gemfile`에 `webrick`도 포함했습니다.
현재 로컬 확인 환경이 Ruby `2.6.10`이어서, macOS에서 최신 `ffi` 플랫폼 gem 충돌을 피하기 위해 `Gemfile`에 `ffi ~> 1.16.3`도 함께 고정했습니다.
만약 `bundle install`이 계속 실패한다면, 더 최신 Ruby 환경에서 다시 설치하거나 GitHub Pages gem README에 나온 Docker 방식도 검토하는 편이 안전합니다.

## 배포 방식

이 저장소는 GitHub Pages가 `main` 브랜치 루트를 직접 읽어 빌드하고 배포합니다.
즉, 별도의 GitHub Actions Jekyll 빌드 워크플로는 필수가 아닙니다.
로컬에서 충분히 확인하고 `main`에 push하면 Pages 쪽 기본 빌드가 진행됩니다.

## 글 작성 규칙

- 파일명은 `_posts/YYYY-MM-DD-english-slug.md`
- front matter에는 최소 `title`, `date`, `tags`, `excerpt` 포함
- 한국어 본문 기준으로 충분한 설명과 예시를 포함
- 정의만 나열하지 말고 적용 기준과 운영 체크포인트를 함께 적기
- GitHub Pages 목록 노출을 위해 미래 시각 포스트를 만들지 않기

초안 생성을 빠르게 하려면 아래 스크립트를 사용할 수 있습니다.

```bash
scripts/new_post.sh \
  "트랜잭션 경계가 서비스 설계에 주는 영향" \
  "transaction-boundary-service-design" \
  "Spring,Database" \
  "트랜잭션 경계는 코드 구조와 장애 범위를 함께 바꿉니다."
```

이 스크립트는 `_posts/` 아래에 새 파일을 만들고, 실행 시각보다 5분 이른 `Asia/Seoul` 기준 시간을 넣습니다.
또한 `Backend` 태그를 자동으로 포함하고, 실무형 글 구조 초안을 함께 생성합니다.
필요하면 `POST_OFFSET_MINUTES=7 scripts/new_post.sh ...`처럼 시간 오프셋을 직접 조절할 수 있습니다.

하루치 3개 초안을 한 번에 만들려면 아래 배치 스크립트를 사용할 수 있습니다.

```bash
cat > /tmp/daily-posts-plan.txt <<'EOF'
JVM 스레드 덤프를 어디부터 읽어야 하는가|jvm-thread-dump-first-pass|Java,Performance|스레드 덤프는 장애 원인을 좁히는 가장 빠른 단서가 될 수 있습니다.
Spring 트랜잭션 전파가 서비스 경계를 흐리는 순간|spring-transaction-propagation-service-boundary|Spring,Database|전파 옵션은 코드 재사용보다 장애 범위를 먼저 바꿉니다.
REST API에서 202 Accepted를 써야 하는 작업과 아닌 작업|rest-api-202-accepted-usage|REST API,HTTP|비동기 작업 응답은 상태 코드 하나로 끝나지 않고 조회 방식까지 함께 설계해야 합니다.
EOF

scripts/new_daily_posts.sh /tmp/daily-posts-plan.txt
```

이 배치 스크립트는 계획 파일의 3개 항목을 읽어 각각 7분 전, 6분 전, 5분 전 시각으로 초안을 생성합니다.

포스트 규칙 검증은 아래 스크립트로 할 수 있습니다.

```bash
ruby scripts/check_posts.rb
```

이 스크립트는 파일명 형식, 필수 front matter, 중복 제목, 중복 slug, 미래 날짜, 파일명 날짜와 front matter 날짜 불일치를 점검합니다.

하루치 주제를 최근 글과 겹치지 않게 고르는 보조 스크립트도 있습니다.

```bash
ruby scripts/suggest_daily_topics.rb
```

이 스크립트는 `_data/daily_topic_pool.yml`의 후보를 기준으로 최근 7일 글과 기존 slug/title을 보고 3개 주제를 추천합니다.
출력 마지막의 `Plan file lines`를 그대로 복사해 `scripts/new_daily_posts.sh` 입력 파일로 사용할 수 있습니다.

예시:

```md
---
title: "트랜잭션 격리 수준이 동시성 버그를 만드는 방식"
date: 2026-06-29 08:50:00 +0900
tags: [Database, Transaction, Backend]
excerpt: "격리 수준은 동시에 들어오는 요청이 어떤 데이터를 보게 할지 결정합니다."
---
```

## 배포 전 확인

```bash
git diff --check
ruby scripts/check_posts.rb
# 로컬 Jekyll 환경이 안정적일 때만 추가
bundle exec jekyll build
```

로컬에 Jekyll이 아직 설치되지 않았다면 최소한 front matter와 날짜, 링크, 제목 중복은 확인하는 편이 좋습니다.
현재처럼 로컬 Ruby가 오래된 환경에서는 `bundle exec jekyll build`보다 GitHub Pages 기본 빌드 결과를 기준으로 확인하는 편이 더 현실적일 수 있습니다.

## 다루는 주제 예시

- Java 비동기 처리와 스레드 풀
- Spring/JPA 트랜잭션, 지연 로딩, N+1
- REST API 상태 코드, 조건부 요청, 중복 방지
- Database 정합성, 인덱스, 락 경합
- Redis, Kafka, 캐시 전략
- CI/CD, Docker, Kubernetes, Observability
- 장애 분석과 운영 체크리스트

## 참고한 공식 문서

- [GitHub Docs: Testing your GitHub Pages site locally with Jekyll](https://docs.github.com/en/pages/setting-up-a-github-pages-site-with-jekyll/testing-your-github-pages-site-locally-with-jekyll)
- [GitHub Pages Ruby Gem](https://github.com/github/pages-gem/blob/master/README.md)
- [Jekyll Documentation](https://jekyllrb.com/docs/)
