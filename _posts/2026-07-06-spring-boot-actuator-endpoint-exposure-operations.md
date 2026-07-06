---
title: "Spring Boot Actuator를 켜기 전에 endpoint 노출 범위를 먼저 정해야 하는 이유"
date: 2026-07-06 08:56:00 +0900
tags: [Spring, Observability, Backend]
excerpt: "Spring Boot Actuator는 health, metrics, loggers, env 같은 운영 정보를 빠르게 제공하지만, 어떤 endpoint를 HTTP로 노출할지 정하지 않으면 장애 분석 도구가 정보 노출 경로가 될 수 있습니다."
---

서비스 장애가 났을 때 `/actuator/health`와 `/actuator/metrics`가 있으면 원인 파악이 빨라진다. 애플리케이션이 살아 있는지, DB 연결이 정상인지, 요청 지연이 어디서 늘었는지 확인할 실마리를 바로 얻을 수 있기 때문이다. 그래서 Spring Boot 프로젝트에 `spring-boot-starter-actuator`를 추가하는 것은 흔한 운영 준비 작업이다.

문제는 Actuator가 "운영에 유용하다"는 이유만으로 넓게 열릴 때 생긴다. `health`는 비교적 안전해 보이지만, `env`, `configprops`, `loggers`, `heapdump`, `threaddump` 같은 endpoint는 서비스 내부 구조나 설정, 런타임 상태를 드러낼 수 있다. 장애 분석에 필요한 정보와 외부에 노출되면 안 되는 정보가 같은 `/actuator` 아래에 모여 있는 셈이다.

따라서 Actuator 설정의 첫 질문은 "무엇을 볼 수 있는가"가 아니라 "누가, 어디서, 어떤 목적으로 볼 수 있어야 하는가"여야 한다. endpoint를 추가하는 것보다 노출 범위와 접근 경로를 먼저 정하는 팀이 운영 사고를 줄인다.

## 문제 상황

예를 들어 내부 관리자만 보려고 Actuator를 켰는데, 애플리케이션과 같은 포트에 `/actuator`가 열려 있고 로드 밸런서가 모든 경로를 외부로 전달한다고 해보자.

```yaml
management:
  endpoints:
    web:
      exposure:
        include: "*"
```

이 설정은 개발 환경에서는 편하다. 어떤 endpoint가 있는지 빠르게 확인할 수 있고, 장애 재현 중에는 로그 레벨도 바꿔볼 수 있다. 하지만 운영에서 그대로 쓰면 필요 이상의 정보가 HTTP로 노출된다. 보안 장비나 인증 프록시가 앞에 있더라도, 경로 예외나 내부망 오해가 있으면 디버깅 도구가 공격 표면이 된다.

더 현실적인 문제도 있다. 쿠버네티스 readiness probe가 `/actuator/health`를 보는데, health detail에 외부 의존성까지 모두 묶어두면 일시적인 외부 API 장애가 곧바로 Pod 제거로 이어질 수 있다. 반대로 너무 단순하게 `UP`만 반환하면 실제 DB 연결 장애를 늦게 알아차린다.

## 핵심 개념

Spring Boot Actuator endpoint는 사용할 수 있는 상태와 외부로 노출되는 상태를 구분해서 봐야 한다. 공식 문서 기준으로 endpoint는 접근이 허용되고 노출되어야 available 상태가 된다. 웹 애플리케이션에서는 보통 `/actuator/{id}` 경로로 노출되며, 기본 예시는 `/actuator/health`다.

Actuator의 가치는 세 가지로 나눌 수 있다. 첫째, `health`와 `info`처럼 상태 확인에 쓰는 endpoint다. 둘째, `metrics`, `prometheus`, `httpexchanges`처럼 관측성 데이터를 제공하는 endpoint다. 셋째, `loggers`, `env`, `threaddump`, `heapdump`처럼 장애 분석에는 강력하지만 노출 위험도 큰 endpoint다.

운영 설정은 이 세 그룹을 같은 수준으로 취급하면 안 된다. 외부 로드 밸런서가 접근해야 하는 것은 보통 health 정도다. 메트릭은 Prometheus나 모니터링 에이전트가 접근할 수 있으면 된다. 런타임 내부 정보 endpoint는 인증된 운영자나 내부 네트워크에서만 제한적으로 열어야 한다.

## 설정으로 보기

운영에서 흔히 쓰는 시작점은 필요한 endpoint만 명시적으로 노출하는 것이다.

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  endpoint:
    health:
      probes:
        enabled: true
      show-details: "never"
```

이 설정은 HTTP로 노출되는 endpoint를 제한한다. `prometheus`는 모니터링 시스템이 scrape할 수 있도록 열고, `health` 상세 정보는 외부에 보여주지 않는다. 상세 정보가 필요하면 별도 인증 경로나 내부 포트에서만 접근하게 만드는 편이 안전하다.

자체 데이터센터나 분리된 네트워크가 있는 환경에서는 management port를 애플리케이션 포트와 나누는 방식도 검토할 수 있다.

```yaml
server:
  port: 8080

management:
  server:
    port: 8081
  endpoints:
    web:
      base-path: /manage
      exposure:
        include: health,prometheus,loggers
```

포트를 나누면 네트워크 정책, 보안 그룹, 방화벽에서 운영 endpoint 접근을 더 명확히 제어할 수 있다. 다만 클라우드 플랫폼이나 컨테이너 환경에서는 별도 포트가 배포 설정, probe 설정, 보안 정책을 더 복잡하게 만들 수 있으므로 이득이 있는지 확인해야 한다.

## 자주 하는 실수

첫 번째 실수는 `include: "*"`를 운영에 그대로 두는 것이다. Actuator endpoint 목록에는 beans, env, configprops, mappings, threaddump, heapdump처럼 내부 구조를 강하게 드러내는 항목이 있다. 설정값은 sanitization 대상이더라도 완전한 비밀 관리 장치로 기대해서는 안 된다.

두 번째 실수는 health endpoint를 장애 판단의 유일한 기준으로 삼는 것이다. `/actuator/health`가 `UP`이어도 특정 API의 p99 지연이 치솟을 수 있고, 큐 적체나 외부 API 오류율은 health에 반영되지 않을 수 있다. health는 "트래픽을 받아도 되는가"에 가깝고, 성능과 품질은 metrics와 trace로 봐야 한다.

세 번째 실수는 readiness와 liveness를 같은 의미로 쓰는 것이다. readiness는 지금 요청을 받을 준비가 되었는지, liveness는 프로세스를 재시작해야 할 정도로 죽었는지에 가깝다. DB가 잠깐 느리다는 이유로 liveness가 실패해 재시작이 반복되면 장애가 더 커질 수 있다.

## 언제 무엇을 열까

외부 트래픽 경로에는 `health`만 두는 것이 기본값에 가깝다. 로드 밸런서나 Kubernetes probe가 상태를 확인해야 하기 때문이다. 이때 응답은 짧고 안정적이어야 하며, 상세 의존성 정보는 숨기는 편이 안전하다.

모니터링 시스템에는 `prometheus`나 필요한 metrics endpoint를 열 수 있다. 단, 접근 주체가 Prometheus 서버인지, 서비스 메시나 에이전트인지에 따라 네트워크 정책을 다르게 잡아야 한다. 메트릭 endpoint는 인증 없이 내부망에만 있다고 가정하기보다, 실제로 어느 네트워크에서 접근 가능한지 확인해야 한다.

운영자용 endpoint는 별도 인증과 감사 로그가 있는 경로로 분리하는 것이 좋다. 특히 `loggers`는 런타임 로그 레벨을 바꿀 수 있어 장애 대응에는 유용하지만, 잘못 사용하면 로그 폭증으로 디스크와 비용을 밀어 올린다. `heapdump`는 민감 데이터가 메모리에 들어 있을 수 있으므로 평소에 열어둘 이유가 거의 없다.

## 운영에서 볼 것

Actuator를 켠 뒤에는 endpoint 자체도 운영 대상이다. `/actuator/prometheus` scrape 실패율, 응답 시간, scrape payload 크기를 확인한다. 메트릭이 너무 많거나 label 조합이 폭증하면 모니터링 시스템 비용과 저장소 부하가 커진다.

health endpoint는 배포 직후와 장애 때의 상태 변화를 확인해야 한다. readiness가 너무 빨리 `UP`이 되면 애플리케이션 초기화가 끝나기 전에 트래픽을 받을 수 있다. 반대로 너무 많은 외부 의존성을 readiness에 묶으면 작은 외부 장애가 전체 서비스 제거로 이어질 수 있다.

보안 측면에서는 외부에서 `/actuator`, `/manage`, `/healthcheck` 같은 경로가 접근 가능한지 정기적으로 스캔한다. "내부망이라 괜찮다"는 말은 로드 밸런서 라우팅, Ingress path, API Gateway 예외 규칙을 확인하기 전까지는 가정일 뿐이다.

## 정리

Spring Boot Actuator는 운영 준비의 핵심 도구지만, endpoint 노출 범위를 정하지 않으면 정보 노출 경로가 된다. 외부에는 health를 작게 열고, 메트릭은 모니터링 주체에 맞춰 제한하며, 내부 분석 endpoint는 인증과 네트워크 제어 뒤에 둬야 한다. health는 생존 여부, metrics는 추세와 품질, loggers와 dumps는 제한적 장애 분석 도구로 나눠 운영하자.

참고한 공식 문서:

- [Spring Boot Reference - Actuator Endpoints](https://docs.spring.io/spring-boot/reference/actuator/endpoints.html)
- [Spring Boot Reference - Monitoring and Management Over HTTP](https://docs.spring.io/spring-boot/reference/actuator/monitoring.html)
- [Spring Boot Reference - Metrics](https://docs.spring.io/spring-boot/reference/actuator/metrics.html)
