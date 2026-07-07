---
title: "GitHub Actions 캐시 키를 느슨하게 잡으면 오래된 의존성이 테스트를 속이는 이유"
date: 2026-07-07 08:57:00 +0900
tags: [CI/CD, GitHub Actions, Backend]
excerpt: "GitHub Actions 캐시는 빌드 시간을 줄이지만, key와 restore-keys를 너무 넓게 잡으면 오래된 의존성이나 다른 브랜치의 산출물이 복원되어 CI 결과를 헷갈리게 만들 수 있습니다."
---

CI가 갑자기 빨라졌는데 로컬에서는 재현되는 테스트 실패가 GitHub Actions에서는 지나간다고 해보자. 로그를 보면 의존성 설치 단계가 거의 생략되어 있다. 캐시가 잘 먹은 것처럼 보이지만, 실제로는 lock file 변경이 반영되지 않은 오래된 캐시를 복원했을 수 있다.

GitHub Actions 캐시는 반복되는 의존성 다운로드와 빌드 준비 시간을 줄이는 좋은 도구다. 하지만 캐시는 "정답 저장소"가 아니라 "이 key에 맞는 이전 파일 묶음"이다. key를 너무 느슨하게 만들거나 restore-keys를 넓게 두면 현재 코드와 정확히 맞지 않는 파일이 들어올 수 있다.

백엔드 프로젝트에서는 Gradle, Maven, npm, pnpm, Docker layer, 테스트 도구 캐시가 모두 CI 시간에 영향을 준다. 캐시를 쓰지 않으면 느리고, 잘못 쓰면 빠르게 틀릴 수 있다. 그래서 캐시 설계의 핵심은 "무엇이 바뀌면 캐시를 버려야 하는가"를 명확히 하는 것이다.

## 문제 상황

가장 흔한 실수는 브랜치와 의존성 파일을 충분히 반영하지 않은 key다.

```yaml
- name: Cache Gradle
  uses: actions/cache@v4
  with:
    path: |
      ~/.gradle/caches
      ~/.gradle/wrapper
    key: gradle-cache
```

이 설정은 항상 같은 key를 쓴다. 한 번 캐시가 만들어지면 의존성 버전이 바뀌어도 같은 캐시가 복원될 수 있다. Gradle이 최종적으로 필요한 것을 다시 받는 경우도 있지만, stale metadata나 plugin cache가 문제를 흐릴 수 있다.

더 나쁜 경우는 build output이나 test fixture를 함께 캐시하는 것이다. 현재 commit에서 새로 만들어야 할 산출물이 예전 실행 결과로 남아 테스트를 통과시키면 CI는 빠르지만 믿기 어려워진다. 캐시는 의존성 다운로드 비용을 줄이는 데 먼저 쓰고, 빌드 산출물 캐시는 정확한 invalidation 기준이 있을 때만 신중히 써야 한다.

## 핵심 개념

GitHub Actions cache는 `key`가 정확히 맞으면 cache hit로 보고 지정한 `path`에 파일을 복원한다. key가 맞지 않으면 cache miss가 되고, job이 성공적으로 끝났을 때 새 cache가 만들어질 수 있다.

`restore-keys`는 key가 정확히 맞지 않을 때 대체 cache를 찾는 규칙이다. 공식 문서에 따르면 restore key는 순서대로 검색되며, 부분 일치가 여러 개 있으면 가장 최근 cache가 복원될 수 있다. 이 동작은 빌드 시간을 줄이는 데 유용하지만, 너무 넓게 잡으면 현재 lock file과 다른 의존성 상태가 들어올 여지가 생긴다.

따라서 key는 "현재 환경과 의존성 상태"를 표현해야 한다. 운영체제, 런타임 버전, package lock file hash, 빌드 도구 버전처럼 캐시 내용에 영향을 주는 값이 들어가야 한다. restore-keys는 실패해도 안전한 범위까지만 느슨하게 둔다.

## 설정으로 보기

Gradle 프로젝트라면 시작점은 lock file, wrapper, OS를 반영하는 것이다.

```yaml
name: backend-ci

on:
  pull_request:
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - uses: actions/setup-java@v5
        with:
          distribution: temurin
          java-version: "21"

      - name: Cache Gradle dependencies
        uses: actions/cache@v4
        with:
          path: |
            ~/.gradle/caches/modules-2
            ~/.gradle/caches/jars-*
            ~/.gradle/wrapper
          key: ${{ runner.os }}-gradle-jdk21-${{ hashFiles('**/*.gradle*', '**/gradle-wrapper.properties', '**/gradle.lockfile') }}
          restore-keys: |
            ${{ runner.os }}-gradle-jdk21-

      - run: ./gradlew test --no-daemon
```

여기서 key는 OS, JDK 버전, Gradle 설정 파일 hash를 포함한다. 의존성 정의나 wrapper가 바뀌면 key도 바뀐다. restore key는 같은 OS와 같은 JDK 범위까지만 느슨하게 열어 둔다.

Node 프로젝트라면 `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock` 같은 lock file hash가 핵심이다. Python이면 `requirements.txt`, `poetry.lock`, `uv.lock`처럼 실제 해석 결과에 영향을 주는 파일을 넣는다. 언어가 달라도 원칙은 같다. dependency graph를 바꾸는 파일이 key에 들어가야 한다.

## restore-keys의 trade-off

restore-keys는 cache miss 때 빈손으로 시작하지 않게 도와준다. 예를 들어 feature branch에서 lock file이 조금 바뀌었을 때 기본 Gradle wrapper나 대부분의 module cache를 재사용하면 CI 시간이 줄어든다.

하지만 restore-keys는 정확도가 아니라 근사치다. `gradle-`처럼 너무 넓게 두면 JDK 버전, OS, 빌드 도구 버전이 다른 cache까지 후보가 될 수 있다. GitHub 문서도 restore key가 순서대로 검색되고 partial match에서는 가장 최근 cache를 쓸 수 있다고 설명한다. 최신 cache가 항상 현재 브랜치에 맞는 cache라는 뜻은 아니다.

그래서 restore-keys는 "틀려도 빌드 도구가 검증하고 다시 받을 수 있는 디렉터리"에만 쓰는 편이 좋다. 예를 들어 의존성 다운로드 cache는 비교적 안전하지만, `build/`, `target/`, generated source, test result는 stale 상태가 결과를 속일 수 있다.

## 자주 하는 실수

첫 번째 실수는 lock file hash를 key에 넣지 않는 것이다. 의존성 버전이 바뀌어도 cache key가 그대로라면 CI는 오래된 상태를 먼저 복원한다. 빌드 도구가 이를 교정할 수 있어도, 디버깅할 때 "지금 정확히 무엇을 썼는지"가 흐려진다.

두 번째 실수는 브랜치별 cache 접근 범위를 오해하는 것이다. GitHub Actions cache는 브랜치와 default branch 검색 규칙, scope 제한의 영향을 받는다. pull request에서 어떤 cache를 읽을 수 있는지 확인하지 않으면 main의 cache가 feature branch에 들어오는 상황을 예상하지 못할 수 있다.

세 번째 실수는 cache hit이면 설치를 완전히 건너뛰는 것이다. 의존성 캐시는 설치 명령을 빠르게 만들기 위한 보조 수단이다. `npm ci`, `gradle test`, `mvn test` 같은 도구 명령은 여전히 현재 lock file과 설정을 기준으로 검증하게 두는 편이 안전하다.

네 번째 실수는 캐시 path를 너무 넓게 잡는 것이다. 홈 디렉터리 전체나 프로젝트 전체를 cache하면 빠져야 할 파일까지 들어간다. 비밀값, 임시 파일, 이전 테스트 결과가 섞일 위험도 있다. 필요한 의존성 디렉터리만 좁게 지정해야 한다.

## 언제 쓰면 좋은가

캐시는 네트워크 다운로드가 반복되고, 같은 lock file을 여러 번 쓰는 프로젝트에서 효과가 크다. Gradle wrapper, Maven local repository 일부, npm package cache, pip wheel cache처럼 의존성 다운로드 비용이 큰 부분이 후보가 된다.

반대로 빌드 산출물 캐시는 적용 기준이 더 까다롭다. compile output을 캐시하려면 source hash, compiler option, JDK version, annotation processor, generated source까지 invalidation 기준에 들어가야 한다. 이 기준을 관리할 자신이 없다면 의존성 캐시부터 적용하는 편이 낫다.

실무 기준은 간단하다. 캐시가 틀려도 다음 빌드 명령이 현재 lock file 기준으로 교정할 수 있으면 캐시해도 된다. 캐시가 틀렸을 때 테스트 결과나 배포 산출물이 조용히 바뀔 수 있으면 피한다.

## 운영에서 볼 것

CI 캐시는 한 번 설정하고 잊는 대상이 아니다. 다음 지표를 정기적으로 본다.

- cache hit ratio와 miss ratio
- cache restore 시간과 save 시간
- 의존성 설치 단계의 실제 소요 시간
- lock file 변경 직후 CI 실패나 이상 통과 여부
- cache key 변경 빈도와 저장소 cache 사용량

cache hit ratio가 높은데 전체 CI 시간이 줄지 않는다면 캐시 대상이 잘못됐을 수 있다. restore와 save 시간이 다운로드 시간보다 길면 오히려 손해다. lock file이 바뀐 직후만 실패한다면 key나 restore-keys 범위를 다시 봐야 한다.

문제가 의심될 때는 한 번 캐시 없이 실행해 비교한다. GitHub Actions에서는 key에 임시 suffix를 붙여 cache miss를 만들거나, workflow_dispatch 입력으로 cache bypass를 둘 수 있다. "캐시를 끄면 실패한다" 또는 "캐시를 끄면 성공한다"는 사실만으로도 조사 방향이 빨라진다.

## 정리

GitHub Actions 캐시는 CI를 빠르게 만들지만, key와 restore-keys가 느슨하면 오래된 의존성이 현재 테스트를 속일 수 있다. OS, 런타임 버전, lock file hash처럼 캐시 내용에 영향을 주는 값을 key에 넣고, restore-keys는 안전한 범위까지만 열어야 한다. 캐시는 빌드 명령을 대체하는 장치가 아니라 현재 의존성 해석을 빠르게 돕는 보조 장치로 다루자.

참고한 공식 문서:

- [GitHub Docs - Dependency caching reference](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching)
- [GitHub Docs - Caching dependencies to speed up workflows](https://docs.github.com/en/actions/using-workflows/caching-dependencies-to-speed-up-workflows)
