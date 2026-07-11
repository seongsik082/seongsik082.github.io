---
title: "Kubernetes HPA가 CPU 60%인데도 스케일 아웃하지 않는 이유"
date: 2026-07-11 08:51:00 +0900
tags: [Kubernetes, Performance, Operations, Backend]
excerpt: "Kubernetes HPA의 CPU utilization은 Pod가 실제로 쓴 CPU만 보는 값이 아니라 resource request를 기준으로 계산됩니다. request 누락, 평균값의 함정, 지표 누락, scale-down stabilization을 함께 보지 않으면 HPA가 멈춘 것처럼 보이는 장애를 놓치게 됩니다."
---

## 문제 상황

트래픽이 급증한 오전에 애플리케이션 Pod의 CPU 사용률이 60~70%까지 올라갔다. 그런데 HPA의 `TARGETS`는 60%로 보이고, replica 수는 계속 2개다. 팀은 “CPU가 높으니 HPA가 즉시 늘어나야 하는 것 아닌가?”라고 생각하지만, 실제로는 HPA가 계산에 사용할 수 있는 값 자체가 없거나, request를 기준으로 한 평균값이 임계값을 넘지 않았을 수 있다.

반대 상황도 흔하다. 애플리케이션 컨테이너는 한계에 가까운데 로그 수집 sidecar가 낮은 CPU를 사용해 Pod 평균을 끌어내린다. HPA는 Pod 전체의 평균을 보고 있어 뜨거운 컨테이너 하나의 포화 상태를 그대로 반영하지 못한다. 스케일 아웃된 뒤에도 새 Pod가 준비되기 전까지 기존 Pod의 지연 시간이 더 튀는 이유가 여기에 있다.

HPA는 백그라운드에서 계속 감시하는 마법의 스위치가 아니라, 일정 주기로 지표를 읽고 desired replicas를 계산하는 제어 루프다. 지표 수집, request 설정, readiness, 정책과 stabilization이 각각 다른 경계를 담당한다. 이 경계를 나누어 봐야 “HPA가 왜 안 늘었나”를 추측하지 않고 설명할 수 있다.

## 핵심 개념

`autoscaling/v2` HPA는 CPU·메모리 같은 resource metric, 애플리케이션의 custom metric, 큐 길이 같은 external metric을 사용할 수 있다. CPU에서 `averageUtilization: 60`을 설정하면 현재 사용량을 Pod의 CPU request와 비교해 평균 utilization을 계산한다. request가 500m이고 실제 사용량이 300m이면 해당 컨테이너의 utilization은 60%다.

그래서 CPU request가 중요하다. 관련 request가 없는 컨테이너가 있으면 해당 Pod의 CPU utilization을 정의할 수 없고, HPA는 그 metric으로 스케일링하지 않을 수 있다. 단순히 limit만 넣었다고 HPA가 동작하는 것은 아니다. request를 “얼마나 배정받고 싶은가”가 아니라 “utilization 계산의 기준”으로 이해해야 한다.

기본 계산은 다음과 비슷하다.

```text
desiredReplicas = ceil(currentReplicas * currentMetric / desiredMetric)

현재 2개 Pod, 평균 CPU utilization 120%, 목표 60%
ceil(2 * 120 / 60) = 4개
```

다만 실제 계산에는 metric 누락, 아직 Ready가 되지 않은 Pod, 삭제 중인 Pod가 반영된다. 여러 metric을 설정하면 HPA는 각 metric이 제안한 desired replica 중 가장 큰 값을 선택한다. 따라서 CPU가 낮아도 처리해야 할 요청 수나 큐 길이가 높으면 scale out할 수 있고, 반대로 custom metric API가 실패한 상태에서 scale down을 제안하면 안전을 위해 축소를 건너뛸 수 있다.

## 설정으로 보기

CPU 기반 HPA를 쓰려면 애플리케이션 컨테이너의 request를 먼저 명확히 둔다.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
spec:
  template:
    spec:
      containers:
        - name: application
          image: example/checkout:2026.07.11
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-api
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-api
  minReplicas: 2
  maxReplicas: 12
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
      selectPolicy: Min
```

이 설정에서 `requests.cpu`가 500m인 Pod가 300m를 쓰면 60%로 계산된다. 실제 서버가 CPU를 더 많이 사용할 수 있는지와는 별개의 값이다. request를 100m로 낮추면 같은 300m 사용량이 300%가 되어 빠르게 scale out할 수 있고, 1 core로 높이면 30%가 된다. request를 튜닝할 때 HPA 반응을 조작하려고 하기보다, 정상 부하에서 Pod 하나가 처리할 수 있는 용량과 스케줄링 요구를 기준으로 정해야 한다.

CPU가 사용자의 실제 병목을 잘 표현하지 않는 서비스라면 큐 길이나 초당 요청 수를 external metric으로 추가하는 편이 낫다. 예를 들어 HTTP API는 CPU 30%여도 외부 결제 응답을 기다리는 요청이 쌓일 수 있다. `autoscaling/v2`에서는 custom 또는 external metric을 추가하고, metric adapter와 해당 API가 정상적으로 등록되어 있는지 확인해야 한다.

## 자주 하는 실수

첫 번째 실수는 CPU limit만 설정하고 request를 비워 두는 것이다. HPA는 limit을 분모로 사용하지 않는다. Deployment의 모든 컨테이너, 특히 sidecar까지 request가 있는지 확인해야 한다. sidecar를 HPA의 기준에서 빼고 싶다면 컨테이너별 resource metric을 사용하는 방식을 검토할 수 있다.

두 번째 실수는 평균 CPU만 보고 포화된 한 컨테이너를 놓치는 것이다. Pod 안에 애플리케이션과 프록시·로그 수집기가 함께 있으면 Pod 평균이 실제 병목을 숨길 수 있다. 애플리케이션 컨테이너의 CPU를 기준으로 보거나, 요청 지연과 큐 길이처럼 사용자가 체감하는 지표를 함께 넣어야 한다.

세 번째 실수는 HPA metric API를 설치하면 자동으로 값이 생긴다고 생각하는 것이다. resource metric은 보통 `metrics.k8s.io` API를 통해 제공되고 Metrics Server 같은 구성 요소가 필요하다. custom metric과 external metric은 각각 해당 API와 adapter가 필요하다. `kubectl get --raw`로 API 응답을 확인하지 않고 HPA YAML만 고치면 원인을 찾기 어렵다.

네 번째 실수는 스케일 아웃 직후 CPU가 떨어졌으니 바로 scale down하도록 두는 것이다. 새 Pod의 이미지 pull, JVM warm-up, cache 준비가 끝나기 전에 지표가 흔들릴 수 있다. HPA에는 scale-down stabilization window와 rate policy가 있으며, 이를 사용하면 짧은 부하 감소로 replica가 급격히 줄었다가 다시 늘어나는 flapping을 줄일 수 있다.

다섯 번째 실수는 readiness와 HPA를 별개로 보는 것이다. 준비되지 않은 Pod의 CPU 샘플은 초기화 과정의 일시적인 사용량일 수 있고, HPA는 초기화 중이거나 metric이 빠진 Pod를 계산에서 조정한다. startupProbe와 readinessProbe가 실제로 “트래픽을 처리할 준비가 된 시점”을 표현하는지 확인하지 않으면 warm-up CPU 때문에 과도하게 늘어나거나, 반대로 준비된 Pod 수가 부족한데 지표가 낮게 보일 수 있다.

## 언제 쓰면 좋은가

CPU 사용량이 요청량과 함께 증가하고, 새 Pod가 추가되면 처리량이 비교적 선형으로 늘어나는 stateless API라면 CPU HPA가 좋은 출발점이다. 이미지 리사이징이나 압축처럼 CPU가 곧 작업량인 워커에도 잘 맞는다.

하지만 외부 API 대기, DB connection pool 대기, Kafka consumer lag, SQS queue backlog가 병목인 서비스는 CPU만으로 충분하지 않다. CPU가 낮은데 latency가 높다면 CPU HPA를 더 민감하게 만드는 대신, 실제 병목을 나타내는 지표를 추가하는 편이 맞다. 여러 metric을 사용할 때는 scale out 방향에서 가장 큰 제안이 선택된다는 점을 고려해 maxReplicas와 비용 한도를 함께 정한다.

판단 기준은 “Pod가 더 늘어나면 정말 처리 능력이 증가하는가”다. DB connection pool이 이미 포화인데 API Pod만 늘리면 DB를 더 세게 누를 수 있다. 이런 경우 HPA 설정 전에 DB active connection, query latency, upstream timeout을 확인하고, Pod당 동시 요청 수를 제한하거나 downstream의 확장 전략을 먼저 설계해야 한다.

## 운영에서 볼 것

장애 시에는 다음 순서로 확인하면 된다.

```bash
kubectl get hpa checkout-api -w
kubectl describe hpa checkout-api
kubectl get deployment checkout-api
kubectl top pod -l app=checkout-api --containers
```

HPA의 `describe` 출력에서는 current metric, desired replicas, `AbleToScale`, `ScalingActive`, `ScalingLimited` 같은 상태와 이벤트를 확인한다. `ScalingActive=False`라면 metric API나 request 누락을 먼저 의심하고, `ScalingLimited=True`라면 min/max 범위에 걸린 것인지 본다. HPA가 원하는 replica를 계산했는데 Deployment의 `availableReplicas`가 따라오지 못하면 스케줄러, 이미지 pull, readiness, 노드 자원을 확인한다.

운영 대시보드에는 HPA가 읽은 metric과 애플리케이션 지표를 나란히 둔다. CPU utilization, request 대비 실제 사용량, Pod 수, Pending/Ready 수, p95·p99 latency, request rate, error rate, queue depth를 함께 보면 “스케일러가 틀렸는지, 스케일된 Pod가 준비되지 않았는지, 애초에 다른 병목인지”를 구분할 수 있다.

scale-down stabilization을 5분으로 두었다면 지표가 낮아진 즉시 replica가 줄지 않는 것이 정상일 수 있다. 반대로 scale-up policy를 너무 느리게 제한하면 급격한 요청 증가를 따라가지 못한다. 정책은 비용 절감보다 사용자 timeout을 먼저 기준으로 정한다. 새 Pod가 Ready가 되는 데 90초 걸리는 서비스라면, 30초 안에 처리해야 하는 요청을 CPU HPA만으로 구하기 어렵다. warm capacity를 minReplicas에 남겨 두거나 예측 기반 사전 확장을 검토해야 한다.

로그와 이벤트에는 HPA 이름, 대상 workload, metric 값, desired/current replicas를 연결해 남긴다.

```text
hpa=checkout-api metric=cpu current=82% target=60% desired=6 currentReplicas=3
hpa=checkout-api reason=FailedGetExternalMetric metric=checkout_queue_depth
deployment=checkout-api desired=6 ready=3 unavailable=3 reason=readiness_timeout
```

이 정보가 있으면 replica 수만 보고 HPA가 멈췄다고 결론 내리는 일을 줄일 수 있다. metric을 못 읽은 것인지, maxReplicas에 도달한 것인지, 새 Pod가 뜨지 못한 것인지가 서로 다른 장애이기 때문이다.

## 정리

HPA의 CPU utilization은 실제 CPU 사용량을 request와 비교해 계산한 값이다.
request가 없거나 metric API가 실패하면 HPA가 그 지표로 움직이지 않을 수 있다.
평균 CPU만으로 병목이 표현되지 않는 서비스에는 큐 길이·요청량·외부 metric을 추가하자.
scale-down stabilization, readiness, Pod 생성 시간까지 포함해야 실제 사용자 지연을 줄일 수 있다.

## 참고한 공식 문서

- [Kubernetes Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Kubernetes Horizontal Pod Autoscaler concepts and algorithm](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)
