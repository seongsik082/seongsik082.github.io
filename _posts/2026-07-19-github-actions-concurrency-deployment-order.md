---
title: "상태를 바꾸는 배포는 왜 최신 run만 남기면 안 되는가"
date: 2026-07-19 08:51:00 +0900
tags: [CI/CD, GitHub Actions, Operations, Backend]
excerpt: "상태를 바꾸는 production 배포에서는 migration·traffic 전환·취소 정책을 함께 검토해야 합니다."
---

## 사례 상태: 설계 시나리오

이 글은 장애 보고서가 아니라, 앞으로 만들 **AgentOps Board KR** 서비스의 production 배포 규칙을 정리한 설계 기록이다. 이 저장소의 블로그는 GitHub Pages가 `main` 브랜치에서 빌드·배포한다. 별도 서비스 배포 workflow가 없으므로 현재 블로그에는 아래 동시성 잠금이 필요하지 않다.

AgentOps Board KR의 승인 배포에는 migration, traffic 전환, 외부 동기화가 들어갈 수 있다. 그래서 “새 commit이 왔으니 이전 run을 취소한다”는 규칙은 검사에는 맞아도 배포에는 위험하다.

결정은 간단하다. **같은 production 환경에는 한 번에 하나의 상태 변경 배포만 실행하고, 실행 중인 배포는 자동 취소하지 않는다.** 모든 commit을 순서대로 반영할지는 대기열 보존 정책과 감사 기록으로 별도 결정한다.

## 먼저 보호할 대상을 나눈다

GitHub Pages 문서 배포와 서비스 배포는 보호 대상이 다르다. Pages의 늦은 빌드는 서비스 DB schema나 외부 상태를 바꾸지 않는다. 이 저장소는 `main` push 뒤 기본 빌드 결과만 확인하면 된다.

AgentOps Board KR에서는 승인 뒤 runner가 특정 SHA의 artifact를 배포하고, migration·health check·traffic 전환을 거쳐 감사 로그를 남긴다. 두 run이 migration이나 traffic 전환을 겹치면 현재 상태를 판단하기 어렵다.

group의 기준은 commit이 아니라 보호할 리소스다. `service-production`처럼 서비스와 환경을 넣고, 같은 환경을 바꾸는 workflow는 같은 group을 쓴다. staging과 production은 분리한다.

## PR 검사와 production 배포의 취소 기준

PR의 lint, unit test, 정적 분석은 대개 최신 commit만 보면 된다. 이런 검사는 PR 번호를 group에 넣고 실행 중인 오래된 검사도 취소한다.

아래 YAML은 이 설계 시나리오의 제안 예시이며, 현재 workflow나 측정된 운영 결과가 아니다.

```yaml
concurrency:
  group: ci-pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true
```

이 정책은 검사 결과가 외부 상태를 바꾸지 않을 때만 쓴다. preview 환경이나 테스트 계정을 만들면, 취소 뒤 정리가 안전하게 재시도되는지도 확인한다.

production은 반대다. migration·traffic 전환·외부 호출은 중단해도 자동으로 되돌아가지 않는다. 실행 중인 배포를 새 commit 때문에 취소하지 않는다.

아래 YAML은 이 설계 시나리오의 제안 예시이며, 현재 workflow나 측정된 운영 결과가 아니다.

```yaml
concurrency:
  group: service-production
  cancel-in-progress: false
```

이 설정은 실행 중인 run을 하나로 제한한다. 다만 `false`가 모든 대기 run을 보존하지는 않는다. 기본 `queue: single`은 running 하나와 pending 하나만 두며, 새 run은 기존 pending을 교체한다. 즉 이 정책은 **실행 중인 변경을 보호**할 뿐 대기 변경을 모두 배포하지 않는다.

특히 기존 column을 삭제하거나 값의 의미를 바꾸는 migration은 이전 artifact가 아직 요청을 처리할 수 있는 시간을 고려해야 한다. 한 run을 직렬화해도 사용자의 장기 요청, background worker, rollback 대상 artifact가 이전 schema를 읽을 수 있다. 그래서 migration은 먼저 호환되는 형태로 넓히고, 이전 코드가 사라진 뒤 정리하는지 deploy script와 runbook에서 확인한다.

## 대기열 규칙을 배포 정책으로 읽기

GitHub Actions concurrency는 같은 group에서 workflow 또는 job 하나만 실행한다. 기본 `queue: single`은 pending 하나만 허용하므로 세 번째 run은 두 번째 pending을 교체한다.

승인된 변경을 모두 적용할 release라면 최대 100개 pending을 두는 `queue: max`를 검토한다. 가득 차면 추가 run은 취소된다. 이는 `cancel-in-progress: true`와 함께 쓸 수 없다.

queue가 있어도 commit dispatch 순서가 보장되지는 않는다. 같은 group은 대기를 시작한 시각 기준으로 FIFO지만 runner 할당과 job 준비 시점은 다르다. 순서가 중요하면 승인·release 번호와 이전 배포 완료를 서비스에서도 확인한다.

group 이름은 대소문자를 구분하지 않아 `Prod`, `prod`, `PROD`가 같다. 소문자와 환경 이름을 쓰고, `service-production-${{ github.sha }}`처럼 SHA를 넣어 lock을 무력화하지 않는다.

## 배포 run을 별도로 기록한다

concurrency는 Actions 안의 실행을 겹치지 않게 할 뿐 migration을 트랜잭션으로 묶거나 traffic 전환을 원자적으로 rollback하지 않는다. rollback은 별도 절차다.

AgentOps Board KR은 Actions run과 별도로 배포 감사 테이블을 남긴다. 시작 SHA·environment, migration·traffic 전환 시각과 상태를 기록하고, 취소된 run도 남긴다.

아래 SQL은 이 설계 시나리오의 제안 예시이며, 현재 구현이나 측정된 운영 결과가 아니다.

```sql
CREATE TABLE deployment_run (
  id UUID PRIMARY KEY,
  git_sha CHAR(40) NOT NULL,
  environment VARCHAR(20) NOT NULL,
  status VARCHAR(20) NOT NULL,
  migration_started_at TIMESTAMPTZ,
  traffic_shifted_at TIMESTAMPTZ,
  rollback_of UUID
);
```

이 테이블은 lock이 아니라 감사 흔적이다. 운영자는 `git_sha`, `status`, migration·traffic 시각으로 중간 상태를 판단하고, `rollback_of`로 되돌림 대상을 연결한다.

## 취소와 rollback 사이에 운영자 판단을 둔다

자동 취소하지 않는다고 문제가 난 배포를 끝까지 진행하는 것은 아니다. health check나 migration이 실패하면 다음 단계를 멈추고 `failed`를 기록한다. traffic 전에는 새 SHA로 다시 시작하고, 뒤에는 rollback·forward migration·요청 제한을 운영자가 결정한다.

Cancel은 rollback이 아니다. runner 중단 요청은 DB 변경·외부 API·이미지 배포를 되돌리지 않는다. 배포 도구는 단계 시작·끝을 기록하고, 취소 때 migration·traffic 시각과 후속 조치를 남긴다.

승인자는 최신 main이 아니라 실제 `git_sha`와 environment를 승인한다. 기본 대기열에서 B가 C로 교체되면 C는 다시 승인한다. `queue: max`도 시작 직전에 각 pending run의 승인을 확인한다.

migration 전 실패는 같은 SHA를 재실행할 수 있다. 시작 후에는 현재 schema와 이력을, traffic 뒤에는 응답률·오류율과 새 rollback run을 확인한다. 이는 concurrency가 아니라 deploy script와 runbook의 책임이다.

## 세 commit으로 정책을 검증한다

production과 같은 group을 쓰되 DB·traffic을 건드리지 않는 검증 환경에서 A·B·C를 연속 배포한다. A가 실행 중일 때 B, B가 pending일 때 C를 넣는다. 기본 대기열과 `cancel-in-progress: false`의 기대값은 아래와 같다.

| commit | Actions에서 관찰할 상태 | `deployment_run`의 migration 시작 여부 | 확인할 판단 |
| --- | --- | --- | --- |
| A | running → completed | 예 | 실행 중인 배포는 C가 와도 자동 취소되지 않는다. |
| B | queued → cancelled | 아니오 | 기본 대기열에서는 새 pending C가 B를 교체한다. |
| C | queued → completed | 예 | A가 끝난 뒤 최신 pending run이 시작한다. |

SHA·run URL·상태 시각과 B의 빈 `migration_started_at`을 기록한다. B도 반영해야 하면 `queue: max` 또는 건별 승인을 결정한다.

## 대안 비교

모든 경로에 `cancel-in-progress: true`를 쓰는 대안은 PR 검사에는 빠르지만 production migration과 외부 side effect에는 쓰지 않는다.

production의 기본 `queue: single`은 실행 중 배포를 보호하고 오래된 pending을 최신 변경으로 압축한다. 중간 버전을 모두 배포해야 하는 조직에는 맞지 않는다.

`queue: max`는 최대 100개 pending을 보존하지만, 독립 배포 가능 여부와 긴 대기열의 알림을 정해야 한다. Actions concurrency는 트랜잭션·원자적 rollback·승인 순서 보장을 제공하지 않는다.

## 이 글에서 제외하는 것

이 결정은 AgentOps Board KR의 배포 직렬화만 다룬다. migration rollback, canary 비율, Kubernetes·cloud 명령, 실제 승인자 설정은 서비스 구현 때 runbook으로 정한다. 블로그 배포를 Actions workflow로 바꾸자는 제안도 아니다.

## 주니어 확인 체크

배포 설정을 읽을 때 먼저 “이 run이 외부 상태를 바꾸는가?”를 묻는다. 아니면 최신 run만 남기는 취소 정책을 고려한다. 맞다면 실행 중 취소를 막고, pending run을 하나만 남길지 최대 100개까지 보존할지를 별도로 결정한다. 마지막으로 group에 environment를 넣었는지, SHA를 넣어 lock을 무력화하지 않았는지, 취소·migration·traffic 전환 시각을 감사 로그에서 찾을 수 있는지 확인한다.

## 참고한 공식 문서

- [GitHub Actions: Control the concurrency of workflows and jobs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
