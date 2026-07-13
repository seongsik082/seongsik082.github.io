---
title: "Kubernetes Rolling update 중 readiness 공백이 생기는 이유"
date: 2026-07-13 08:51:00 +0900
tags: [Kubernetes, CI/CD, Operations, Backend]
excerpt: "Kubernetes RollingUpdate는 새 Pod를 만들고 이전 Pod를 줄이는 순서를 제어하지만, readiness가 실제 트래픽 수용 가능 시점을 정확히 표현하지 못하면 배포 중 오류율이 튑니다. maxSurge, maxUnavailable, 종료 처리와 애플리케이션 준비 상태를 함께 설계해야 합니다."
---

## 문제 상황

배포 파이프라인은 성공했고 `kubectl rollout status`도 완료를 출력했습니다. 그런데 바로 그 시간대에 502와 timeout이 늘어납니다. 새 Pod는 `Running`이고 `READY 1/1`인데, 첫 요청에서 DB 연결을 만들고 캐시를 채우느라 수 초 동안 실패하거나 매우 느리게 응답합니다. 이전 Pod는 이미 종료 중이라 트래픽을 받을 수 없습니다.

이 문제를 단순히 “Kubernetes가 Pod를 너무 빨리 지웠다”라고 보면 해결이 어렵습니다. RollingUpdate의 용량 계산, readiness probe의 의미, 애플리케이션의 graceful shutdown이 서로 다른 상태를 보고 있기 때문입니다. Pod가 프로세스를 실행 중이라는 사실과 실제로 사용자 요청을 처리할 준비가 됐다는 사실은 같지 않습니다.

## RollingUpdate가 보장하는 것

Deployment의 RollingUpdate는 새 ReplicaSet을 점진적으로 늘리고 이전 ReplicaSet을 줄입니다. `maxSurge`는 원하는 replica 수를 초과해 추가로 만들 수 있는 Pod 수이고, `maxUnavailable`은 업데이트 중 사용할 수 없어도 허용되는 Pod 수입니다. 기본값이 25%이므로 replica 수가 작은 서비스에서는 실제 절대 개수로 환산했을 때 예상과 다른 동작이 나올 수 있습니다.

예를 들어 replica가 4이고 `maxSurge: 1`, `maxUnavailable: 0`이면 새 Pod를 하나 더 만들 수 있지만, 새 Pod가 available 상태가 되기 전에는 이전 Pod를 줄일 수 없습니다. 이 설정은 용량 보존에 유리하지만 새 Pod가 Ready가 되지 않으면 rollout이 계속 멈춥니다. 반대로 `maxUnavailable: 1`을 허용하면 새 Pod가 준비되는 동안 기존 Pod 하나를 먼저 줄일 수 있어 배포 속도와 용량 사이의 trade-off가 생깁니다.

Kubernetes가 말하는 `available`은 단순히 컨테이너가 실행 중이라는 뜻이 아닙니다. Pod가 Ready가 된 뒤 `minReadySeconds` 동안 안정적으로 유지되어야 available로 계산되게 만들 수 있지만, readiness endpoint가 무엇을 검사하는지가 실제 안정성을 결정합니다.

## readiness와 종료 흐름

readiness probe는 “이 컨테이너가 지금 Service 트래픽을 받아도 되는가”를 묻습니다. 실패하면 해당 Pod의 IP가 Service의 EndpointSlice에서 빠지므로 새 요청을 보내지 않는 방향으로 동작합니다. liveness probe는 deadlock 같은 상태에서 컨테이너를 재시작할지 판단하고, startup probe는 느린 초기화가 끝날 때까지 liveness와 readiness를 기다리게 하는 역할입니다.

배포가 시작되면 다음과 같은 흐름이 생깁니다.

1. 새 revision의 Pod가 생성되지만 startup 또는 readiness가 통과하지 않아 기존 Pod만 트래픽을 받는다.
2. readiness가 성공하면 새 Pod가 EndpointSlice에 들어가고 요청을 받기 시작한다.
3. Deployment가 `maxUnavailable` 규칙에 따라 이전 Pod를 종료시킨다.
4. 종료 중인 Pod는 kubelet이 graceful termination을 시작하고, 일반 트래픽용 endpoint의 `ready`는 false가 된다.
5. 새 Pod가 실제 dependency 초기화까지 끝내지 못했다면, 이전 Pod가 빠지는 순간 용량과 성공률에 공백이 생긴다.

여기서 readiness가 포트가 열렸는지만 확인하면 문제가 생깁니다. 포트는 열렸지만 마이그레이션 호환성 확인, DB pool 초기화, 캐시 warm-up, 필수 downstream 연결이 끝나지 않은 상태일 수 있습니다. readiness는 가능한 한 실제 요청 경로에서 필요한 최소 dependency를 검사해야 하되, 외부 시스템 전체의 건강 검사를 매번 호출해 readiness 자체가 병목이 되지 않게 해야 합니다.

## 코드로 보기

다음은 용량 공백을 줄이기 위한 출발점입니다. 숫자는 서비스의 시작 시간과 replica 수를 측정한 뒤 조정해야 합니다.

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: 4
  minReadySeconds: 15
  progressDeadlineSeconds: 600
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    spec:
      terminationGracePeriodSeconds: 45
      containers:
        - name: app
          startupProbe:
            httpGet:
              path: /internal/health/startup
              port: 8080
            periodSeconds: 5
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /internal/health/readiness
              port: 8080
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          lifecycle:
            preStop:
              httpGet:
                path: /internal/drain
                port: 8080
```

`/internal/health/readiness`는 애플리케이션이 “새 요청을 받아도 되는 상태”일 때만 성공해야 합니다. `/internal/drain`은 애플리케이션이 신규 요청 수용을 끄고 진행 중인 요청을 정리하도록 구현한 예입니다. hook을 추가했다고 자동으로 모든 요청이 안전하게 끝나는 것은 아니므로, 서버의 connection draining, keep-alive, 비동기 작업의 종료 정책을 함께 검증해야 합니다.

`terminationGracePeriodSeconds`는 preStop과 SIGTERM 이후 정리를 완료할 수 있는 충분한 시간이어야 합니다. 기본 grace period에 맞춰 긴 작업을 처리하려 하면 KILL 전에 작업이 끊길 수 있습니다. 반대로 무조건 크게 잡으면 terminating Pod가 오래 남아 rollout 중 실제 리소스 사용량이 늘고, 새 Pod를 띄울 노드 여유가 부족해질 수 있습니다.

## 흔한 readiness 설계 실수

첫 번째는 liveness와 readiness에 같은 endpoint를 쓰는 것입니다. DB가 일시적으로 느려졌을 때 readiness만 false가 되어 트래픽을 다른 Pod로 옮기는 것이 안전할 수 있지만, liveness까지 같은 이유로 실패하면 정상적으로 복구할 수 있는 Pod를 반복 재시작할 수 있습니다. 재시작이 필요한 “살아 있지 않음”과 라우팅에서 잠시 빼야 하는 “받을 준비가 안 됨”을 나눠야 합니다.

두 번째는 readiness가 너무 빨리 성공하거나 외부 검사에 과하게 의존하는 것입니다. 애플리케이션이 HTTP 서버를 열자마자 200을 반환하면 JVM warm-up이나 connection pool 생성이 끝나기 전에 요청이 도착할 수 있고, 반대로 모든 downstream을 검사하면 잠깐의 지연에도 모든 Pod가 NotReady가 될 수 있습니다. startup probe와 `minReadySeconds`로 초기화 시간을 분리하되, readiness에는 요청 처리에 반드시 필요한 최소 상태만 넣습니다.

세 번째는 rollout 완료를 사용자 성공률과 같은 의미로 보는 것입니다. 새 ReplicaSet이 원하는 수까지 만들어졌다는 것은 Kubernetes 관점의 진행 상태일 뿐이므로 API의 5xx, timeout, p95, DB connection acquisition time과 일치하는지 별도로 봐야 합니다.

## 언제 조정하고 언제 전략을 바꿀까

`maxUnavailable: 0`과 작은 `maxSurge`는 무중단 용량이 중요한 API에 유용하지만, 새 Pod를 띄울 CPU·메모리 여유가 클러스터에 있어야 합니다. 위험한 DB 스키마 변경이나 외부 계약 변경처럼 일부 트래픽에서 먼저 호환성을 확인해야 하는 변경은 canary·blue-green과 명시적인 rollback 조건을 별도로 설계하는 편이 안전합니다.

rollout이 멈추면 `progressDeadlineSeconds`가 Deployment 상태에 `ProgressDeadlineExceeded`를 남기게 할 수 있습니다. 이것은 자동 rollback을 대신하지 않으므로, 배포 파이프라인이 해당 상태를 실패로 처리하고 로그·이벤트·이미지 pull·probe 응답을 수집하도록 해야 합니다.

## 운영에서 볼 것

배포 전후에는 다음을 같은 시간축으로 확인합니다.

- `kubectl rollout status deployment/checkout-api`
- `kubectl get deploy,rs,pods -l app=checkout-api -o wide`
- 새 Pod의 readiness 실패 횟수와 첫 Ready까지 걸린 시간
- EndpointSlice에서 ready·terminating endpoint의 변화
- API 5xx, timeout, p95·p99, in-flight 요청 수
- DB pool 대기, 캐시 miss, downstream timeout, CPU·메모리와 Pending Pod 수

특히 새 Pod가 Ready가 된 순간부터 오류율이 튀었는지, 이전 Pod가 Terminating으로 바뀐 순간부터 용량이 줄었는지를 비교하면 원인을 빠르게 좁힐 수 있습니다. `kubectl describe deployment`의 Events에서 이미지 pull과 probe 실패를 확인하고, 애플리케이션 로그에서는 SIGTERM 이후에도 새 요청을 받았는지와 진행 중 요청이 얼마 만에 끝났는지를 봅니다.

## 정리

RollingUpdate는 새 Pod와 이전 Pod의 개수를 조절하지만 애플리케이션의 실제 준비 상태까지 대신 정의하지는 않는다.
readiness는 라우팅 가능 여부, liveness는 재시작 여부, startup은 초기화 대기를 표현하도록 분리한다.
`maxSurge`, `maxUnavailable`, `minReadySeconds`, 종료 grace period는 replica 수와 실제 시작·종료 시간을 측정해 정해야 한다.
rollout 성공 여부와 사용자 성공률을 같은 지표로 보지 말고, 배포 중 EndpointSlice·5xx·timeout·downstream 대기를 함께 확인하자.

## 참고한 공식 문서

- [Kubernetes Documentation - Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
- [Kubernetes Documentation - Liveness, Readiness, and Startup Probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/)
- [Kubernetes Documentation - Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
