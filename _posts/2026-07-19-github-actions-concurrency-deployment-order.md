---
title: "GitHub Actions concurrency로 중복 배포와 오래된 롤백을 막는 설계 기준"
date: 2026-07-19 08:51:00 +0900
tags: [CI/CD, GitHub Actions, Operations, Backend]
excerpt: "GitHub Actions workflow가 동시에 실행되면 오래된 commit이 새 배포 결과를 덮어쓸 수 있습니다. concurrency group, cancel-in-progress, pending 처리와 production 배포·PR 검사의 차이를 기준으로 안전한 적용 방법을 정리합니다."
---

## 문제 상황

`main`에 짧은 시간 동안 두 commit이 push됐습니다. 첫 번째 workflow는 느린 integration test를 통과한 뒤 배포 중이었고, 두 번째 workflow는 더 최신 이미지로 배포를 시작했습니다. 그런데 첫 번째 workflow가 뒤늦게 끝나면서 이전 commit의 이미지를 production에 다시 올렸습니다. Git에는 최신 코드가 있는데 서버는 오래된 코드인 상태가 된 것입니다.

반대 문제도 있습니다. pull request마다 전체 테스트를 실행하면 이전 commit의 결과가 최신 commit에 필요하지 않은데도 runner를 오래 점유합니다. GitHub Actions는 기본적으로 workflow와 job을 동시에 실행하므로, 검사와 배포의 “같은 대상에 대한 동시 실행”을 직접 제한해야 합니다.

## concurrency가 제어하는 범위

`concurrency`는 같은 group을 사용하는 workflow 또는 job을 한 번에 하나만 실행하도록 묶는 기능입니다. 실행 중인 하나와 대기 중인 하나가 있을 때, 기본 pending 정책에서는 새 실행이 이전 pending 실행을 대체합니다. `cancel-in-progress: true`를 추가하면 실행 중인 이전 run도 취소합니다.

PR 검사는 최신 commit만 의미가 있으므로 다음처럼 설정할 수 있습니다.

```yaml
name: pull-request-ci

on:
  pull_request:

concurrency:
  group: ci-${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./gradlew test
```

여기서는 같은 PR의 새 commit이 오면 이전 테스트를 중단합니다. 다른 PR의 테스트까지 막지 않으려면 group에 PR 번호를 넣어야 합니다. 반대로 repository 전체의 같은 workflow가 branch별로 한 번만 실행되어야 한다면 `github.ref`나 workflow 이름을 기준으로 묶습니다.

## production 배포에는 cancel을 신중하게 쓴다

production 배포는 “최신 것만 남기면 된다”는 규칙으로 처리하기 어렵습니다. 이미 migration을 실행했거나 traffic 전환을 시작한 run을 강제로 취소하면, 새 run이 그 중간 상태를 이해하지 못할 수 있습니다. 따라서 production 배포는 동시 실행을 막되, 실행 중인 배포를 취소할지와 대기 run을 모두 보존할지를 따로 정해야 합니다.

가장 보수적인 시작점은 다음과 같습니다.

```yaml
on:
  push:
    branches: [main]

concurrency:
  group: production-deploy
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      - run: ./scripts/deploy.sh "${{ github.sha }}"
```

이 설정은 production 배포를 한 번에 하나만 실행하게 합니다. pending run은 기본적으로 최신 run이 이전 pending을 대체할 수 있으므로, 모든 commit을 순서대로 배포해야 한다면 queue 설정을 별도로 검토해야 합니다. queue와 `cancel-in-progress: true`는 함께 쓰지 않습니다.

group 이름은 workflow와 환경을 포함해 충돌을 피합니다. `deploy-${{ github.workflow }}-production`처럼 구분하고, group 이름은 대소문자를 구분하지 않는다는 점도 기억해야 합니다.

## cancel-in-progress의 적용 기준

PR lint·unit test·정적 분석이나 최신 결과만 필요한 preview 배포에는 `cancel-in-progress: true`가 잘 맞습니다. 반대로 DB migration, traffic 전환, 되돌리기 어려운 외부 side effect가 있는 production 배포는 취소 전에 중단·복구 절차를 설계해야 합니다.

이런 workflow는 배포 단계를 작은 job으로 나누고, 각 단계가 재실행 가능하거나 명시적인 rollback을 갖는지 확인해야 합니다. concurrency는 배포 단계를 원자적으로 만들어 주는 기능이 아니라, 같은 대상에 여러 실행이 겹치지 않게 하는 잠금에 가깝습니다.

## 흔한 설정 실수

첫 번째는 group에 commit SHA를 넣는 것입니다. 그러면 모든 run이 서로 다른 group이 되어 동시성 제한이 사라집니다. 대상 branch, PR 번호, environment처럼 실제로 보호하려는 리소스를 key에 넣어야 합니다.

두 번째는 workflow-level과 job-level concurrency를 같은 의미로 보는 것입니다. 전체를 막을지 deploy job만 막고 build는 병렬로 허용할지 목적에 따라 위치를 정합니다.

세 번째는 취소된 run과 실패한 run을 구분하지 않는 것입니다. 운영 대시보드에는 commit SHA, 시작 시각, 취소 여부, 배포 대상, rollback 결과를 남겨야 “최신 run이 성공했다”와 “중간 배포를 취소했다”를 나눌 수 있습니다.

## 운영에서 확인할 지표

배포 workflow에는 queued 시간, 실행 시간, canceled run 수, 동일 group의 동시 실행 시도, commit SHA별 production 반영 시각을 기록합니다. 최근 배포가 느려졌다면 runner가 부족한지, group에서 오래 pending인지, 실제 deploy step이 느린지 나눠 봐야 합니다.

정리하면 다음과 같습니다.

- concurrency group은 같은 배포 대상의 동시 실행을 막는 안전장치입니다.
- PR 검사는 최신 run만 남겨도 되지만 production 배포는 취소 가능성과 rollback을 별도로 판단해야 합니다.
- group에 branch·PR·workflow·environment를 반영하고 workflow 간 이름 충돌을 피해야 합니다.
- concurrency는 원자적 배포나 rollback을 대신하지 않으므로 각 단계의 재실행 가능성을 함께 설계해야 합니다.

## 참고한 공식 문서

- [GitHub Actions - Concurrency](https://docs.github.com/en/actions/concepts/workflows-and-actions/concurrency)
- [GitHub Actions - Control the concurrency of workflows and jobs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
