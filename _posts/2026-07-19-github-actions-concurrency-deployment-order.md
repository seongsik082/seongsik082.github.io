---
title: "상태를 바꾸는 배포는 왜 최신 run만 남기면 안 되는가"
date: 2026-07-19 08:51:00 +0900
tags: [CI/CD, GitHub Actions, Operations, Backend]
excerpt: "상태를 바꾸는 production 배포에서는 migration·traffic 전환·취소 정책을 함께 검토해야 합니다."
---

## 사례 상태: 설계 시나리오

이 글은 장애 보고서가 아니라, 앞으로 만들 **AgentOps Board KR** 서비스의 production 배포 규칙을 정리한 설계 결정 기록이다. 이 저장소의 블로그는 GitHub Pages가 `main` 브랜치 루트를 직접 읽어 빌드·배포한다. 별도의 GitHub Actions 서비스 배포 workflow가 없으므로, 현재 블로그 배포에는 아래의 Actions 동시성 잠금이 필요하지 않다.

대신 AgentOps Board KR에는 운영자가 승인한 배포가 있다. DB schema를 바꾸는 migration, 사용자 요청을 새 버전으로 보내는 traffic 전환, 외부 시스템에 남기는 동기화 작업이 한 run 안에 들어갈 수 있다. 이 경로에서 “새 commit이 왔으니 이전 run을 모두 취소한다”는 규칙은 검사에는 효율적이지만 배포에는 위험할 수 있다.

결정은 간단하다. **같은 production 환경에는 한 번에 하나의 상태 변경 배포만 실행하고, 실행 중인 배포는 자동 취소하지 않는다.** 모든 commit을 순서대로 반영할지는 대기열 보존 정책과 감사 기록으로 별도 결정한다.

## 먼저 보호할 대상을 나눈다

GitHub Pages 문서 배포와 서비스 배포는 둘 다 “배포”라는 이름을 쓰지만 보호 대상이 다르다. Pages는 Markdown과 정적 파일을 새 사이트로 만드는 경로다. 이전 빌드가 늦게 끝나도 서비스 DB의 schema나 외부 결제 상태를 바꾸지는 않는다. 이 저장소는 `main`에 push한 뒤 Pages 기본 빌드 결과를 확인하면 된다.

반면 AgentOps Board KR의 요청 흐름은 다음처럼 상태를 지난다. 운영자가 변경을 승인하고, runner가 특정 commit SHA의 artifact를 배포한 뒤, migration을 실행하고, health check를 통과하면 traffic을 전환한다. 마지막에는 어느 SHA가 언제 어느 환경을 바꿨는지 감사 로그를 남긴다. 이전 run과 다음 run이 migration이나 traffic 전환을 동시에 하면, “어느 버전이 현재 상태인가”를 판단하기 어려워진다.

따라서 group의 기준은 commit이 아니라 보호할 리소스다. production 환경을 보호한다면 `service-production`처럼 서비스와 환경을 나타내는 이름을 쓴다. staging과 production이 서로 영향을 주지 않아야 한다면 환경별로 group을 분리한다. 여러 workflow가 같은 환경을 건드린다면 workflow 이름만으로 분리하지 말고, 실제로 같은 환경을 바꾸는 작업은 같은 group을 공유하게 해야 한다.

## PR 검사와 production 배포의 취소 기준

PR의 lint, unit test, 정적 분석은 최신 commit의 결과만 알면 되는 경우가 많다. 같은 PR에 commit을 세 번 push했다면 첫 번째와 두 번째 검사가 끝나기를 기다릴 이유가 없다. 이런 검사는 PR 번호를 group에 넣고 `cancel-in-progress: true`로 설정한다. 새 commit이 오면 실행 중인 오래된 검사도 멈춰 runner 시간을 최신 검증에 쓸 수 있다.

```yaml
concurrency:
  group: ci-pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true
```

이 정책은 검사 결과가 외부 상태를 바꾸지 않는다는 전제가 있어야 한다. preview 환경을 지우거나 테스트용 계정을 만드는 단계가 있다면, 취소되어도 정리 작업이 안전하게 재시도되는지 확인한다. “CI니까 취소해도 된다”가 아니라, 중간에 멈춰도 남는 상태가 운영에 영향을 주지 않는지가 기준이다.

production은 기준이 반대다. migration이 시작된 뒤 run을 취소하면, 새 run이 어떤 schema까지 적용됐는지 모른 채 시작할 수 있다. traffic 전환 중에 중단하면 일부 요청은 이전 버전, 일부 요청은 새 버전으로 갈 수 있다. 외부 알림이나 파트너 API 호출도 한 번 실행되면 GitHub Actions가 자동으로 되돌릴 수 없다. 그래서 실행 중인 production 배포를 새 commit 때문에 자동 취소하지 않는다.

```yaml
concurrency:
  group: service-production
  cancel-in-progress: false
```

이 설정은 같은 group에서 실행 중인 run을 하나로 제한한다. 그러나 `false`는 “모든 대기 run을 보존한다”는 옵션이 아니다. 기본 `queue: single`에서는 실행 중인 run 하나와 pending run 하나만 둘 수 있다. 같은 group에 새 run이 들어오면 기존 pending run은 취소되고, 새 run이 그 자리를 차지한다. 이 글의 production 정책은 **실행 중인 변경을 보호**하는 정책이며, 아직 시작하지 않은 변경을 모두 배포한다는 정책은 아니다.

## 대기열 규칙을 배포 정책으로 읽기

GitHub Actions concurrency는 같은 group에서 한 번에 하나의 workflow 또는 job만 실행하게 한다. 하지만 대기 처리에는 선택지가 있다. 기본값은 `queue: single`이며 pending run을 최대 하나만 허용한다. 세 번째 run이 들어오면 두 번째 pending run은 cancelled가 되고 세 번째 run이 pending이 된다. “최신 요청으로 대기열을 압축”하는 동작에 가깝다.

승인된 변경을 빠짐없이 하나씩 적용해야 하는 release라면 `queue: max`를 검토한다. 이 값은 같은 group에 pending run을 최대 100개까지 둔다. 대기열이 가득 찬 뒤 들어온 추가 run은 취소된다. `queue: max`와 `cancel-in-progress: true`는 함께 쓸 수 없으며, 함께 쓰면 workflow 검증 오류가 난다. 실행 중인 run을 취소하면서 대기 run을 모두 보존하겠다는 두 규칙이 충돌하기 때문이다.

여기서 “queue가 있으니 commit dispatch 순서대로 배포된다”고 단정하면 안 된다. 같은 group의 job 또는 run은 concurrency group을 기다리기 시작한 시각을 기준으로 FIFO 처리되지만, workflow가 dispatch된 시각 기준으로 waiting/start 순서는 보장되지 않는다. runner 할당과 job 준비 시점이 다르기 때문이다. 순서가 법적·업무적으로 중요하다면 Actions 화면의 순서가 아니라 승인 번호, release 번호, 이전 배포 완료 여부를 서비스 쪽에서 함께 검증해야 한다.

group 이름도 의외로 사고를 만든다. group 이름은 대소문자를 구분하지 않아 `Prod`, `prod`, `PROD`는 같은 group이다. 이름 규칙을 소문자로 통일하고, 환경을 포함해 의도를 보이게 한다. 반대로 `service-production-${{ github.sha }}`처럼 commit SHA를 넣으면 매 run의 group이 달라진다. 그 결과 서로 잠그지 못하고, 가장 피하려던 동시 migration과 traffic 전환이 다시 가능해진다.

## 배포 run을 별도로 기록한다

concurrency는 GitHub Actions 안에서 실행이 겹치지 않게 하는 제어일 뿐이다. migration을 트랜잭션으로 묶어 주지도 않고, 중단된 traffic 전환을 원자적으로 rollback하지도 않는다. rollback은 이전 artifact를 재배포할지, forward migration을 적용할지, traffic을 어디까지 되돌릴지에 대한 별도 절차여야 한다.

그래서 AgentOps Board KR은 Actions run 정보만 믿지 않고 서비스의 배포 감사 테이블도 남긴다. 예를 들어 배포 시작 직후 SHA와 environment를 기록하고, migration 직전과 traffic 전환 직후에는 시각과 상태를 갱신한다. 취소된 run도 지우지 않고 `cancelled` 상태로 남겨야, 승인된 변경이 시작 전 취소됐는지 중간에 사람이 중단했는지 확인할 수 있다.

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

이 테이블은 배포 자체를 잠그는 장치가 아니다. lock은 Actions concurrency와 배포 도구가 맡고, 테이블은 무엇이 일어났는지 설명하는 감사 흔적을 맡는다. 운영자는 `git_sha`, `status`, `migration_started_at`, `traffic_shifted_at`을 함께 보고 “코드는 배포됐지만 traffic은 아직 전환되지 않았다” 같은 중간 상태를 판단한다. `rollback_of`에는 되돌리는 대상 run의 id를 넣어, rollback이 단순 실패와 섞이지 않게 한다.

## 취소와 rollback 사이에 운영자 판단을 둔다

실행 중인 production run을 자동 취소하지 않는다고 해서, 문제가 난 배포를 끝까지 진행한다는 뜻은 아니다. health check가 실패하거나 migration 오류가 나면 deploy script는 다음 단계를 진행하지 않고 `failed` 상태를 기록해야 한다. traffic 전환 전이라면 해당 artifact를 폐기하고 원인을 고친 새 SHA로 다시 시작할 수 있다. 이미 traffic을 전환했다면 이전 artifact로 되돌릴지, 호환되는 forward migration을 추가할지, 사용자 요청을 잠시 제한할지를 운영자가 결정한다.

중요한 점은 GitHub Actions의 Cancel 버튼을 rollback 버튼으로 보지 않는 것이다. Cancel은 runner에 중단을 요청할 뿐 DB 변경, 외부 API 호출, 이미지 배포 결과를 하나의 트랜잭션처럼 되돌리지 않는다. 배포 도구는 각 단계의 시작과 끝을 기록하고, 중단 신호를 받았을 때 어느 단계까지 실행됐는지 `deployment_run`에 남겨야 한다. 사람이 run을 취소한 경우에도 `status`만 `cancelled`로 바꾸지 말고 migration과 traffic 전환 시각을 확인한 뒤 후속 조치를 기록한다.

승인도 같은 경계에서 다룬다. 배포 승인자는 “현재 main의 최신 SHA”가 아니라 실제로 실행할 `git_sha`와 environment를 승인한다. 대기 중이던 B가 C로 교체된 기본 대기열에서는 B의 승인이 C로 자동 승계됐다고 가정하면 안 된다. C는 C의 SHA로 다시 승인·감사 대상이 된다. 반대로 `queue: max`를 사용하는 release는 각 pending run의 승인 상태가 유효한지 시작 직전에 다시 확인한다. 이렇게 해야 Actions 화면의 run 번호와 서비스 감사 로그의 배포 대상이 어긋나지 않는다.

재시도 기준도 미리 좁혀 둔다. migration 시작 전 실패는 같은 SHA를 재실행할 수 있지만, migration 시작 후 실패는 현재 schema와 migration 도구의 이력부터 확인한다. traffic 전환 후 실패는 정상 응답률과 오류율을 확인하고 rollback run을 새로 만든다. 이전 run을 단순히 Re-run하는 것이 항상 안전한 것은 아니다. 이 기준은 concurrency가 아닌 deploy script와 runbook이 책임질 부분이며, 따라서 Actions 설정만으로 완료됐다고 판단하지 않는다.

## 세 commit으로 정책을 검증한다

설정을 main에 바로 믿고 적용하지 않는다. production과 같은 group을 쓰되 실제 DB와 traffic을 건드리지 않는 검증 환경을 만들고, 같은 environment에 commit A·B·C를 연속으로 배포한다. A가 migration 직전 또는 실행 중일 때 B를 push하고, B가 pending인 상태에서 C를 push한다. 기본 대기열과 `cancel-in-progress: false`라면 아래 기록이 기대값이다.

| commit | Actions에서 관찰할 상태 | `deployment_run`의 migration 시작 여부 | 확인할 판단 |
| --- | --- | --- | --- |
| A | running → completed | 예 | 실행 중인 배포는 C가 와도 자동 취소되지 않는다. |
| B | queued → cancelled | 아니오 | 기본 대기열에서는 새 pending C가 B를 교체한다. |
| C | queued → completed | 예 | A가 끝난 뒤 최신 pending run이 시작한다. |

표의 SHA, run URL, queued·cancelled·completed 시각을 배포 변경 기록에 붙이고, B의 `migration_started_at`이 비어 있는지도 확인한다. B까지 반드시 반영해야 하는 승인 release라면 `queue: max`로 바꿔 최대 100개의 pending을 허용할지, release를 한 건씩 승인할지 결정한다.

## 대안 비교

첫 번째 대안은 모든 경로에 `cancel-in-progress: true`를 적용하는 것이다. 최신 코드 확인이 목표인 PR 검사에는 가장 빠르고 합리적이다. 하지만 production의 migration과 외부 side effect에는 적용하지 않는다. 멈춘 run의 실제 영향이 GitHub의 cancelled 표기만으로 사라지지 않기 때문이다.

두 번째 대안은 production에 기본 `queue: single`을 유지하는 것이다. 실행 중인 배포는 보호하면서 오래된 대기 배포를 최신 변경으로 압축한다. feature commit처럼 중간 버전을 독립적으로 반영할 필요가 없을 때 단순하다. 다만 각 승인 건이 모두 배포돼야 하는 조직에는 맞지 않는다.

세 번째 대안은 production에 `queue: max`를 쓰고 release 단위를 명시하는 것이다. 최대 100개의 pending run을 보존할 수 있지만, 각 run이 정말 독립적으로 배포 가능한지와 대기열이 길어졌을 때 누구에게 알릴지를 운영 절차로 정해야 한다. Actions concurrency는 트랜잭션도, 원자적 rollback도, 승인 순서의 업무 보장도 제공하지 않는다.

## 이 글에서 제외하는 것

이 결정은 AgentOps Board KR의 배포 직렬화 기준만 다룬다. migration SQL의 세부 rollback 전략, canary 비율, Kubernetes 또는 cloud provider 명령, GitHub Environment의 실제 승인자 설정은 서비스가 만들어질 때 별도 runbook으로 확정한다. 현재 GitHub Pages 블로그의 배포 방식을 Actions workflow로 바꾸자는 제안도 아니다.

## 주니어 확인 체크

배포 설정을 읽을 때 먼저 “이 run이 외부 상태를 바꾸는가?”를 묻는다. 아니면 최신 run만 남기는 취소 정책을 고려한다. 맞다면 실행 중 취소를 막고, pending run을 하나만 남길지 최대 100개까지 보존할지를 별도로 결정한다. 마지막으로 group에 environment를 넣었는지, SHA를 넣어 lock을 무력화하지 않았는지, 취소·migration·traffic 전환 시각을 감사 로그에서 찾을 수 있는지 확인한다.

## 참고한 공식 문서

- [GitHub Actions: Control the concurrency of workflows and jobs](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
