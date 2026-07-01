---
title: "Kubernetes CPU limit를 습관처럼 넣으면 p99 지연이 튀는 이유"
date: 2026-07-01 08:51:00 +0900
tags: [Kubernetes, Performance, Backend]
excerpt: "Kubernetes의 CPU limit는 안전장치처럼 보이지만, 지연 시간에 민감한 서비스에서는 hard limit가 오히려 p99 응답 시간을 키울 수 있습니다."
---

## 문제 상황

Kubernetes에 애플리케이션을 올릴 때 많은 팀이 `requests`와 `limits`를 세트처럼 넣습니다. 얼핏 보면 당연한 습관처럼 보입니다. 요청량이 늘어도 한 파드가 CPU를 과하게 먹지 못하게 막아 주고, 클러스터 전체 자원도 공정하게 쓸 수 있을 것 같기 때문입니다.

하지만 운영에서는 CPU 사용률 평균이 높지 않은데도 p99 응답 시간이 갑자기 튀는 일이 있습니다. GC가 길어진 것도 아니고, DB가 느린 것도 아니고, 애플리케이션 로그도 특별히 이상하지 않습니다. 이런 상황에서 실제 원인이 CPU limit에 의한 throttling인 경우가 적지 않습니다. 평균 CPU는 멀쩡해 보여도 짧은 순간 필요한 CPU를 못 쓰면 요청 대기가 밀리기 때문입니다.

실무에서 더 헷갈리는 부분은, 같은 YAML이 개발 환경에서는 멀쩡하고 운영에서만 문제를 만든다는 점입니다. 로컬이나 저부하 환경에서는 순간적인 CPU 경쟁이 잘 드러나지 않지만, 운영에서는 스파이크 구간의 짧은 제약이 그대로 tail latency로 번집니다.

## 핵심 개념

Kubernetes 공식 문서는 CPU request를 스케줄링 기준으로, CPU limit를 커널이 강제로 집행하는 hard limit로 설명합니다. 문서 표현대로 컨테이너가 CPU limit에 가까워지면 커널이 CPU 접근을 제한하고, 컨테이너는 limit 이상 CPU를 사용할 수 없습니다. 여기서 중요한 점은 "조금 느려질 수 있다"가 아니라 "필요한 순간에도 더 못 쓴다"는 것입니다.

지연 시간에 민감한 API 서버는 CPU를 항상 많이 쓰는 서비스가 아닐 수 있습니다. 평소에는 200m만 쓰다가도 JSON 직렬화, 압축, 암호화, GC 보조 작업, 특정 요청 몰림 때문에 짧은 순간 1 core 이상이 필요할 수 있습니다. 이때 limit가 너무 타이트하면 평균 사용량은 낮아도 순간 스파이크를 흡수하지 못합니다. 그 결과 큐 대기, 응답 지연, 타임아웃 재시도가 이어집니다.

또 하나 많이 놓치는 규칙이 있습니다. Kubernetes는 limit만 지정하고 request를 비워 두면, 별도 기본값이 없는 한 limit 값을 request로 복사합니다. 즉, "일단 limit만 넣자"는 가벼운 선택이 실제로는 스케줄러에게도 같은 값을 요구하는 설정이 됩니다. 이 때문에 파드가 예상보다 덜 밀집되거나, 반대로 request를 높게 잡은 채 HPA 판단이 왜곡될 수 있습니다.

## YAML로 보기

문제가 자주 생기는 설정은 아래와 비슷합니다.

```yaml
resources:
  requests:
    cpu: "500m"
    memory: "512Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"
```

이 설정은 보기엔 단순하지만, CPU는 0.5 core를 넘는 순간 커널이 바로 제한합니다. 부하가 일정한 배치 작업이라면 괜찮을 수 있지만, 요청형 웹 애플리케이션에서는 짧은 burst를 허용하지 못해 tail latency를 키울 수 있습니다.

대신 아래처럼 시작하는 편이 더 현실적일 때가 많습니다.

```yaml
resources:
  requests:
    cpu: "500m"
    memory: "512Mi"
  limits:
    memory: "512Mi"
```

이 방식은 메모리는 OOM 보호를 위해 제한하되, CPU는 request만 주고 limit는 두지 않습니다. 물론 멀티테넌트 클러스터 정책상 CPU limit가 강제되는 환경도 있습니다. 핵심은 "항상 넣는 관성"이 아니라 "이 서비스가 burst CPU를 써야 하는가"를 먼저 판단하는 것입니다.

## 자주 하는 실수

첫 번째 실수는 CPU와 메모리를 같은 감각으로 다루는 것입니다. 메모리 limit는 초과 시 OOM kill 같은 강한 결과로 이어지고, CPU limit는 throttling으로 이어집니다. 둘 다 제한이지만 증상이 다릅니다. 메모리는 죽고, CPU는 살아 있으면서 느려집니다. 그래서 CPU 문제는 더 늦게 발견됩니다.

두 번째 실수는 HPA 지표를 보며 "평균 CPU가 60%밖에 안 되니 괜찮다"고 결론 내리는 것입니다. throttling은 평균값보다 짧은 구간의 제한에서 문제가 커집니다. 평균 CPU가 안정적이어도 특정 시점에 CPU 사용이 잘려 나가면 p99만 나빠질 수 있습니다.

세 번째 실수는 limit 없이 운영하는 것과 request 없이 운영하는 것을 같은 위험으로 보는 것입니다. request는 스케줄링과 자원 예약의 기준이고, limit는 실행 중 상한입니다. 둘을 구분하지 않으면 파드 배치, 자동 확장, 성능 문제를 한 번에 오해하게 됩니다.

## 언제 쓰면 좋은가

CPU limit가 잘 맞는 경우는 사용 패턴이 비교적 평평하고, 순간 burst가 크게 중요하지 않은 배치성 작업이나 강한 테넌트 격리가 필요한 환경입니다. 반대로 사용자 요청을 직접 처리하는 API 서버, 짧은 응답 시간을 요구하는 서비스, 암호화나 직렬화 burst가 있는 서비스는 limit를 매우 신중하게 넣어야 합니다.

실무 판단 기준을 하나만 고르면 이렇습니다. "지연 시간에 민감한 서비스라면 CPU limit를 기본값으로 넣지 말고, request부터 잡은 뒤 throttling과 p99를 같이 본다." 클러스터 정책상 limit가 필요하다면 최소한 request와 같은 값으로 묶지 말고 burst 여유가 필요한지부터 검토해야 합니다.

## 운영에서 볼 것

- 컨테이너 CPU throttling 관련 메트릭
- 응답 시간 p95/p99와 CPU 사용률의 시점별 상관관계
- HPA scale out 직전의 request latency 증가
- GC 시간, 직렬화 시간, 압축 시간처럼 짧은 CPU burst가 생기는 구간
- limit만 지정해 request가 의도치 않게 복사된 파드가 있는지 여부

아래 같은 질문을 붙여 보면 더 빨리 판단할 수 있습니다.

- CPU 평균은 낮은데 p99만 나빠지는가
- scale out 전후로 throttling이 줄어드는가
- 같은 애플리케이션이 limit 제거 후 tail latency가 안정되는가

## 정리

Kubernetes의 CPU limit는 안전장치이지만, 지연 시간에 민감한 서비스에서는 hard limit가 순간 burst를 잘라 p99 지연을 키울 수 있습니다. request와 limit는 역할이 다르고, limit만 넣으면 request가 복사된다는 점도 같이 봐야 합니다. 운영에서는 평균 CPU보다 throttling 신호와 tail latency를 함께 확인하는 편이 실제 문제를 더 빨리 잡습니다.

## 참고한 공식 문서

- Kubernetes Docs, Resource Management for Pods and Containers: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
