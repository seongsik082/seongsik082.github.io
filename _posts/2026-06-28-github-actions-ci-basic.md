---
title: "GitHub Actions로 CI 흐름을 처음 만들 때 볼 것들"
date: 2026-06-28 22:00:00 +0900
tags: [CI/CD, GitHub Actions, Backend]
excerpt: "CI는 코드를 합치기 전에 빌드와 테스트를 자동으로 실행해 변경의 안전성을 확인하는 흐름입니다."
---

백엔드 프로젝트에서 CI를 붙이는 이유는 단순히 자동화를 멋지게 보이게 하려는 것이 아닙니다.
기능을 수정할 때마다 사람이 직접 빌드하고 테스트하면 언젠가는 빠뜨리는 단계가 생깁니다.
CI는 저장소에 변경이 올라오는 순간 정해둔 검증 절차를 반복해서 실행하게 만들고, 실패를 빠르게 드러내는 장치입니다.

## CI와 CD를 나누어 생각하기

CI는 Continuous Integration, 즉 지속적 통합입니다.
여러 사람이 만든 변경을 자주 합치되, 합치기 전에 빌드와 테스트가 통과하는지 확인합니다.
CD는 Continuous Delivery 또는 Continuous Deployment로, 검증된 결과물을 배포 가능한 상태로 만들거나 실제 환경에 배포하는 단계입니다.

처음부터 배포까지 자동화하려고 하면 설정 범위가 커집니다.
처음에는 `push`나 `pull_request` 이벤트에서 테스트만 자동으로 돌리는 작은 CI부터 시작하는 편이 좋습니다.

## 워크플로 파일의 기본 구조

GitHub Actions의 워크플로는 저장소의 `.github/workflows` 폴더에 있는 YAML 파일로 정의합니다.
하나의 워크플로는 실행 조건인 `on`, 실제 작업 묶음인 `jobs`, 각 작업의 실행 환경인 `runs-on`, 그리고 순서대로 실행되는 `steps`로 읽을 수 있습니다.

```yaml
name: Backend CI

on:
  push:
    branches: [ main ]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Run tests
        run: ./gradlew test
```

이 예시는 `main` 브랜치에 푸시되거나 pull request가 열릴 때 테스트를 실행합니다.
`runs-on`은 job이 실행될 머신 종류를 정하고, `steps` 안의 `uses`는 이미 만들어진 action을 사용하며, `run`은 직접 쉘 명령을 실행합니다.

## 실패했을 때 읽기 쉬운 CI

좋은 CI는 실패했을 때 원인을 좁히기 쉬워야 합니다.
빌드, 테스트, 정적 분석, 패키징을 한 줄 명령으로 모두 묶어버리면 어느 단계에서 깨졌는지 보기 어렵습니다.
처음에는 단계 이름을 분명하게 붙이고, 실패 로그가 너무 길어지지 않게 나누는 것이 좋습니다.

예를 들어 Gradle 프로젝트라면 다음처럼 나눌 수 있습니다.

```yaml
steps:
  - uses: actions/checkout@v6
  - name: Check Java version
    run: java -version
  - name: Run unit tests
    run: ./gradlew test
```

실무에서는 캐시, 테스트 리포트 업로드, Docker 이미지 빌드 같은 단계가 더해질 수 있습니다.
하지만 처음부터 모든 기능을 넣기보다 "변경이 들어왔을 때 최소한 깨진 코드를 발견한다"는 목적을 먼저 만족시키는 것이 중요합니다.

## 백엔드 프로젝트에서 챙길 점

백엔드 CI에서는 테스트 DB, 환경 변수, 외부 API 의존성을 특히 조심해야 합니다.
로컬에서는 `.env` 파일이나 개인 PC의 DB 덕분에 통과하던 테스트가 CI에서는 실패할 수 있습니다.
그래서 테스트에 필요한 값은 GitHub Secrets나 테스트 전용 설정으로 분리하고, 외부 서비스 호출은 가짜 객체나 테스트 컨테이너로 대체하는 전략을 세워야 합니다.

또 하나 중요한 점은 CI가 느려질수록 개발자가 결과를 기다리지 않게 된다는 것입니다.
처음에는 가장 중요한 테스트를 빠르게 돌리고, 시간이 오래 걸리는 검증은 별도 workflow로 분리하는 방식도 고려할 수 있습니다.

CI는 팀의 약속을 자동으로 확인하는 문입니다.
작게 시작하더라도 빌드와 테스트가 자동으로 실행되면, 코드를 합칠 때의 불안이 줄고 문제를 더 빠르게 발견할 수 있습니다.

참고한 공식 문서: [GitHub Actions workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
