---
title: "Kubernetes 종료에서 preStop과 grace period를 가볍게 보면 롤링 배포 중 연결 끊김이 남는 이유"
date: 2026-07-05 08:59:00 +0900
tags: [Kubernetes, Operations, Backend]
excerpt: "Kubernetes는 Pod 삭제 시 자동으로 종료 절차를 밟지만, preStop 훅과 terminationGracePeriodSeconds를 대충 두면 롤링 배포나 scale down 동안 기존 요청이 중간에 끊기고 장시간 Terminating Pod가 쌓일 수 있습니다."
---

## 문제 상황

롤링 배포를 할 때 평소에는 문제없다가도 특정 시간대에만 502나 `connection reset`이 보이는 서비스가 있습니다. 새 Pod는 정상적으로 뜨고 readiness도 통과했는데, 이전 Pod가 내려가는 순간 일부 요청이 응답을 끝내지 못하고 끊기는 식입니다.

이 상황은 특히 API 서버가 외부 결제사 호출, 큰 파일 업로드, 긴 DB 트랜잭션, 스트리밍 응답처럼 "요청 하나가 오래 사는" 경우에 자주 나타납니다. 운영자는 Pod가 `Terminating`으로 바뀌었으니 새 요청은 더 안 들어올 거라고 기대하지만, 실제로는 이미 열린 연결과 종료 훅, 애플리케이션 종료 시간이 서로 다른 속도로 움직입니다.

문제는 Kubernetes가 종료 절차를 대신해 준다고 해서 애플리케이션의 뒷정리 방식까지 대신 설계해 주는 것은 아니라는 점입니다. 종료 신호를 받은 뒤 언제 새 작업을 멈출지, 기존 작업을 얼마나 기다릴지, 그 시간을 grace period 안에 어떻게 맞출지를 애플리케이션과 Pod 스펙이 함께 결정해야 합니다.

## 핵심 개념

Kubernetes 문서는 Pod 종료 시 `terminationGracePeriodSeconds`가 0이 아니면 kubelet이 먼저 `preStop` 훅을 실행한다고 설명합니다. 중요한 점은 이 훅이 비동기로 따로 도는 것이 아니라는 것입니다. 공식 문서상 `PreStop`은 종료 신호와 분리되어 독립적으로 도는 작업이 아니며, 훅이 끝나야 컨테이너에 종료 신호가 전달됩니다.

즉, `preStop` 10초 + 애플리케이션 종료 25초가 필요한데 grace period를 30초로 두면 이미 설계가 맞지 않습니다. Kubernetes는 grace period가 끝나면 남은 프로세스를 강제로 종료합니다. Pod lifecycle 문서도 기본 `terminationGracePeriodSeconds`는 30초이고, 훅이 끝나지 않으면 kubelet이 짧은 추가 시간을 요청한 뒤 결국 강제 종료로 넘어간다고 적고 있습니다.

또 하나 중요한 사실은 terminating Pod가 곧바로 "세상에서 사라지는" 것은 아니라는 점입니다. Kubernetes 문서는 terminating 상태의 엔드포인트가 EndpointSlice에서 즉시 제거되지 않을 수 있지만, `ready` 상태는 `false`로 노출되어 일반 트래픽 대상에서는 제외된다고 설명합니다. 따라서 종료 설계의 핵심은 "새 요청이 더 늦게 끊기는가"뿐 아니라 "이미 들어온 요청을 애플리케이션이 얼마나 안전하게 마무리하는가"입니다.

결국 graceful shutdown은 세 단계로 봐야 합니다. 첫째, 새 요청을 가능한 빨리 받지 않게 만든다. 둘째, 이미 진행 중인 요청은 정리 시간을 준다. 셋째, 그 모든 시간이 `terminationGracePeriodSeconds` 안에 들어오도록 맞춘다. 셋 중 하나라도 어긋나면 배포 때만 보이는 간헐 오류가 남습니다.

## YAML로 보기

아래처럼 종료용 엔드포인트와 readiness를 분리해 두면 흐름을 설명하기 쉽습니다.

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 40
      containers:
        - name: api
          image: example/api:1.0.0
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - "wget -qO- http://127.0.0.1:8080/internal/drain && sleep 5"
          readinessProbe:
            httpGet:
              path: /health/readiness
              port: 8080
            periodSeconds: 3
```

이 예시에서 의도는 분명합니다.

- `preStop` 시작 시 애플리케이션에 "이제 새 작업을 받지 말라"는 drain 신호를 보냅니다.
- readiness는 곧 실패하도록 바뀌고, Service 라우팅 대상에서 빠질 준비를 합니다.
- 짧은 `sleep`은 ingress, kube-proxy, 외부 LB 전파 지연을 흡수하는 완충 구간입니다.
- 그 뒤 애플리케이션은 진행 중인 요청을 마무리하고 종료합니다.

여기서 중요한 것은 `sleep` 자체가 정답이 아니라는 점입니다. 비즈니스 로직이 20초 걸리는데 5초만 기다리면 여전히 요청이 잘립니다. 반대로 응답이 보통 100ms 안에 끝나는 서비스에 30초 `sleep`을 넣으면 롤링 배포 속도만 느려집니다. sleep은 측정값을 보고 최소한으로 두는 편이 낫습니다.

## 자주 하는 실수

첫 번째 실수는 `preStop` 안에 무거운 작업을 몰아넣는 것입니다. 큰 파일 업로드 정리, 오래 걸리는 flush, 외부 시스템 호출을 훅에서 다 해버리면 Pod가 오래 `Terminating` 상태에 머물고, grace period를 넘기면 결국 강제 종료됩니다. Kubernetes 문서도 훅 핸들러는 가능한 가볍게 유지하라고 권장합니다.

두 번째 실수는 애플리케이션의 실제 종료 시간을 모른 채 `terminationGracePeriodSeconds`를 기본 30초로 방치하는 것입니다. 긴 요청이 35초까지 갈 수 있다면 그 수치로는 구조적으로 부족합니다. 이때 필요한 것은 감이 아니라 p95, p99 요청 시간과 종료 중 in-flight 요청 개수입니다.

세 번째 실수는 readiness probe와 종료 제어를 같은 개념으로 보는 것입니다. readiness는 라우팅 대상을 조정하는 신호이고, graceful shutdown은 이미 받은 일을 어떻게 끝낼지의 문제입니다. readiness만 실패하게 해도 기존 연결은 남을 수 있으므로, 애플리케이션 레벨의 drain 로직이 같이 있어야 합니다.

네 번째 실수는 force delete에 익숙해지는 것입니다. 급하다고 `--grace-period=0 --force`를 남용하면 Kubernetes 문서가 경고하듯 워크로드에 꽤 파괴적일 수 있습니다. 연결형 서비스에서 이것은 "종료를 빠르게 한다"가 아니라 "진행 중이던 일을 끊는다"에 가깝습니다.

## 언제 쓰면 좋은가

HTTP API, gRPC, 메시지 소비자, 배치 워커처럼 "작업 중간 종료"가 장애나 중복 처리로 이어질 수 있는 서비스라면 graceful shutdown 설계를 배포 스크립트만큼 중요하게 봐야 합니다. 특히 외부 결제, 멱등하지 않은 쓰기, 큰 응답 스트림은 종료 순간이 곧 장애 순간이 되기 쉽습니다.

반대로 정말 짧은 read-only 요청만 처리하고, 중간 종료의 비용이 거의 없으며, 상위 재시도가 충분히 안전한 시스템이라면 복잡한 drain 훅 없이 단순한 종료도 가능할 수 있습니다. 다만 이 판단 역시 실제 트래픽 특성 위에서 내려야 합니다.

실무 기준을 한 줄로 줄이면 이렇습니다. "Pod가 종료될 때 가장 오래 사는 정상 요청을 잘라 먹지 않는가?" 이 질문에 자신 없으면 종료 시나리오를 부하 테스트나 카나리 배포에서 다시 측정해야 합니다.

## 운영에서 볼 것

- 롤링 배포나 HPA scale down 직후 5xx, broken pipe, reset 비율
- Pod가 `Terminating` 상태에 머무는 시간 분포
- 종료 직전과 직후의 in-flight request 수
- ingress, service mesh, LB access log에서 draining 중 요청이 어디로 갔는지
- 강제 종료(`SIGKILL`에 해당하는 패턴)가 반복되는지

운영에서는 "새 Pod가 잘 떴는가"만 보면 절반만 본 것입니다. 이전 Pod가 얼마나 예쁘게 내려갔는지까지 봐야 롤링 배포가 진짜 무중단에 가까워집니다.

## 정리

Kubernetes graceful shutdown은 `preStop`, readiness, `terminationGracePeriodSeconds`가 각각 따로 있는 기능이 아니라 하나의 종료 계약입니다. `preStop`은 grace period 안에서 실행되고, terminating 엔드포인트는 일반 트래픽에서 빠지지만, 이미 진행 중인 작업은 애플리케이션이 스스로 정리해야 합니다. 배포 중 남는 502를 줄이려면 종료 시간을 감으로 정하지 말고, 가장 오래 걸리는 정상 요청을 기준으로 drain 순서를 설계해야 합니다.

## 참고한 공식 문서

- [Kubernetes Docs: Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
- [Kubernetes Docs: Container Lifecycle Hooks](https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/)
