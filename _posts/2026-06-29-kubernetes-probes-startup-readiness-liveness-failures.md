---
title: "Kubernetes probe를 섞어 쓰면 생기는 장애와 분리 기준"
date: 2026-06-29 08:52:00 +0900
tags: [Kubernetes, Operations, Backend]
excerpt: "readiness, liveness, startup probe는 모두 health check처럼 보이지만, 실패했을 때 Kubernetes가 취하는 조치는 서로 완전히 다릅니다."
---

Kubernetes 운영에서 자주 보는 장애 중 하나는 애플리케이션 자체보다 health probe 설정이 더 큰 문제를 만드는 경우입니다.
파드는 떠 있지만 트래픽을 받으면 안 되는 상태인데 readiness가 느슨해서 요청이 들어오거나, 반대로 일시적인 외부 의존성 장애를 liveness가 죽음으로 오인해 컨테이너를 계속 재시작하기도 합니다.
결과적으로 원래는 작았던 장애가 재시작 폭증, 배포 지연, 연쇄 타임아웃으로 커집니다.

문제의 출발점은 세 probe가 모두 "상태를 확인한다"는 공통점만 보고 같은 기준으로 구현하는 데 있습니다.
하지만 Kubernetes 공식 문서가 설명하듯 `startupProbe`, `readinessProbe`, `livenessProbe`는 실패 시 의미가 다릅니다.
readiness는 트래픽 대상에서 빼는 판단이고, liveness는 컨테이너를 다시 시작하는 판단이며, startup은 느린 초기화를 기다리는 보호 장치입니다.

## 각 probe가 실제로 하는 일

세 probe를 한 문장씩만 정리하면 다음과 같습니다.

- `startupProbe`: 애플리케이션이 아직 뜨는 중인지 판단한다. 성공하기 전까지 readiness와 liveness는 비활성화된다.
- `readinessProbe`: 지금 이 파드가 요청을 받아도 되는지 판단한다. 실패하면 Service 엔드포인트에서 제외된다.
- `livenessProbe`: 프로세스가 회복 불가능한 상태에 빠졌는지 판단한다. 실패하면 kubelet이 컨테이너를 재시작한다.

이 차이를 무시하면 다음 같은 구성이 나옵니다.

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8080

readinessProbe:
  httpGet:
    path: /health
    port: 8080
```

겉보기에는 단순하지만, `/health`가 DB 연결 실패까지 한꺼번에 체크한다면 순간적인 DB 지연만으로 liveness가 실패해 컨테이너가 재시작됩니다.
이건 장애를 복구하는 것이 아니라, 이미 느린 시스템에 재시작 비용과 connection storm을 추가하는 선택일 수 있습니다.

## liveness에는 "재시작하면 나아지는 문제"만 넣어야 한다

liveness는 가장 공격적인 probe입니다.
실패하면 컨테이너가 죽고 다시 시작됩니다.
따라서 liveness는 "프로세스가 데드락에 빠졌거나 이벤트 루프가 멈췄거나, 메모리 손상처럼 재시작 외에는 회복이 어려운 상황"을 감지하는 데 써야 합니다.

반대로 다음 항목은 liveness에 넣기 좋지 않습니다.

- 외부 DB 순간 장애
- Redis, Kafka 같은 의존 서비스 일시적 타임아웃
- 서드파티 API 응답 지연
- 배치 락 획득 실패

이들은 애플리케이션이 살아 있으면서도 잠시 일을 못 하는 상태일 수 있습니다.
이런 문제까지 liveness가 재시작으로 대응하면, 모든 파드가 같은 시점에 함께 죽고 다시 뜨는 연쇄 장애가 생길 수 있습니다.
실무에서는 "재시작이 치료인가, 단지 더 비싼 반응인가"를 먼저 따져야 합니다.

## readiness는 트래픽 수용 가능성에 집중해야 한다

readiness는 외부 요청을 받아도 되는지를 나타냅니다.
예를 들어 애플리케이션이 기동은 끝났지만 캐시 워밍이 덜 되었거나, 필수 설정 로딩이 끝나지 않았거나, 내부 큐가 꽉 차 백프레셔를 걸어야 하는 경우라면 readiness를 `false`로 두는 편이 맞습니다.

다만 readiness도 너무 무겁게 만들면 안 됩니다.
probe가 실행될 때마다 여러 DB 쿼리나 외부 API 호출을 하면, health check 자체가 부하가 됩니다.
readiness는 가볍고 결정적이어야 하며, "이 파드가 요청을 받아도 비즈니스적으로 안전한가"만 빠르게 판단해야 합니다.

예시는 다음과 같습니다.

```yaml
startupProbe:
  httpGet:
    path: /health/startup
    port: 8080
  periodSeconds: 5
  failureThreshold: 24

readinessProbe:
  httpGet:
    path: /health/ready
    port: 8080
  periodSeconds: 5
  failureThreshold: 2

livenessProbe:
  httpGet:
    path: /health/live
    port: 8080
  periodSeconds: 10
  failureThreshold: 3
```

여기서 `/health/live`는 "프로세스가 응답 가능한가" 정도만 확인하고, `/health/ready`는 애플리케이션 내부 상태를 더 봐도 됩니다.
느린 기동이 예상되면 `startupProbe`가 먼저 충분한 시간을 벌어줘야 합니다.

## startupProbe 없이 느린 기동 앱을 운영하면 배포가 흔들린다

JVM 워밍업, 대형 캐시 초기화, 마이그레이션 확인, 모델 로딩이 필요한 서비스는 기동 직후 수십 초 이상 준비가 안 될 수 있습니다.
이때 startupProbe 없이 liveness만 두면, 애플리케이션이 정상적으로 뜨는 중인데도 kubelet은 "응답이 없네, 죽었나 보다"라고 판단해 재시작을 반복할 수 있습니다.

공식 문서가 startupProbe를 별도로 둔 이유가 바로 여기에 있습니다.
startupProbe가 성공하기 전에는 liveness와 readiness 검사가 시작되지 않으므로, 느린 부팅 애플리케이션을 보호할 수 있습니다.
이 설정이 없으면 배포 시 새 파드가 충분히 뜨기도 전에 계속 교체되고, 결국 롤아웃이 지연되거나 실패합니다.

## 장애 패턴은 probe 자체보다 임계치 설정에서 자주 터진다

엔드포인트 분리만으로 충분하지 않은 경우도 많습니다.
`timeoutSeconds`, `periodSeconds`, `failureThreshold` 조합이 너무 공격적이면 GC pause나 순간적인 CPU 경합에도 실패로 판정됩니다.
반대로 너무 느슨하면 진짜로 죽은 파드를 너무 오래 살려둡니다.

실무적으로는 다음 질문이 유효합니다.

- 평소 p99 응답 시간이 300ms인데 probe timeout이 1초면 충분한가
- 초기 기동 시간이 70초까지 나올 수 있는데 startup failure window가 그보다 짧지 않은가
- readiness가 내려간 뒤 로드밸런서/Service에서 실제로 빠지는 데 걸리는 시간을 감안했는가
- rolling update 중 `maxUnavailable`, `maxSurge`와 probe 지연이 함께 계산되었는가

probe는 단독 설정이 아니라 배포 전략과 묶어서 봐야 합니다.
readiness가 늦게 올라오는데 `maxUnavailable`까지 공격적이면, 정상 버전이 충분히 남아 있지 않은 상태에서 배포가 진행될 수 있습니다.

## 운영에서 확인할 지표와 로그

probe 문제를 볼 때는 애플리케이션 로그만으로 부족합니다.
다음 항목을 함께 봐야 원인을 좁힐 수 있습니다.

- 파드 재시작 횟수와 재시작 직전 이벤트
- readiness 실패 시점과 5xx 증가 시점의 상관관계
- rollout 진행 시간과 새 ReplicaSet의 Ready 파드 수
- GC pause, CPU throttling, 메모리 압박과 probe timeout의 동시 발생 여부
- kubelet 이벤트에서 probe failed 메시지와 상세 원인

특히 "외부 의존성 장애 -> readiness 하락 -> 트래픽 우회"는 좋은 반응일 수 있지만, "외부 의존성 장애 -> liveness 실패 -> 전 파드 재시작"은 대개 나쁜 반응입니다.
로그와 메트릭을 읽을 때 이 차이를 먼저 구분해야 합니다.

## 정리

Kubernetes probe는 모두 health check처럼 보이지만 실패했을 때의 조치는 완전히 다릅니다.
liveness는 재시작이 치료인 문제만 감지해야 하고, readiness는 트래픽 수용 가능성에 집중해야 하며, startup은 느린 초기화를 보호해야 합니다.
probe 엔드포인트를 분리하지 않으면 작은 의존성 지연이 재시작 폭풍으로 커질 수 있습니다.
운영에서는 엔드포인트 분리, 임계치 조정, 배포 전략을 함께 설계하는 편이 가장 안전합니다.

참고한 공식 문서:
- [Kubernetes: Liveness, Readiness, and Startup Probes](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/)
