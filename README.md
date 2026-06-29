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

## CI 빌드

저장소에는 [`.github/workflows/jekyll-build.yml`](.github/workflows/jekyll-build.yml) 워크플로가 포함되어 있습니다.
GitHub Actions에서 Ruby `3.2` 기준으로 `bundle exec jekyll build`를 실행하므로, 로컬 Ruby 환경이 오래되어도 저장소 기준 빌드 성공 여부를 확인할 수 있습니다.

## 글 작성 규칙

- 파일명은 `_posts/YYYY-MM-DD-english-slug.md`
- front matter에는 최소 `title`, `date`, `tags`, `excerpt` 포함
- 한국어 본문 기준으로 충분한 설명과 예시를 포함
- 정의만 나열하지 말고 적용 기준과 운영 체크포인트를 함께 적기
- GitHub Pages 목록 노출을 위해 미래 시각 포스트를 만들지 않기

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
bundle exec jekyll build
```

로컬에 Jekyll이 아직 설치되지 않았다면 최소한 front matter와 날짜, 링크, 제목 중복은 확인하는 편이 좋습니다.

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
