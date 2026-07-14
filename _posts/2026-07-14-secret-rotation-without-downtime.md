---
title: "시크릿을 무중단으로 교체하려면 어디를 분리해야 하는가"
date: 2026-07-14 08:52:00 +0900
tags: [Security, AWS, Operations, Backend]
excerpt: "시크릿 교체는 저장소의 값을 바꾸는 작업이 아니라 외부 시스템의 인증 허용 범위, 애플리케이션 캐시, 연결 풀, 이전 값의 폐기 시점을 분리하는 운영 프로토콜입니다. AWS Secrets Manager의 version stage와 애플리케이션 refresh 전략을 함께 설계해야 교체 순간의 401과 재연결 폭주를 줄일 수 있습니다."
---

## 문제 상황

운영 중인 API key를 교체하기 위해 Secrets Manager의 값을 바꾸고 모든 Pod를 재시작했습니다. 일부 Pod는 새 키를 사용했고 일부는 캐시에 남은 이전 키를 사용하면서 외부 API의 401 비율이 튀었습니다. DB 비밀번호를 바꾼 경우에는 오래된 connection pool이 계속 동작하다가 새 연결을 만드는 순간 인증 실패가 발생해, 교체 직후가 아니라 몇 분 뒤 장애가 나타나기도 합니다.

시크릿을 무중단으로 교체하려면 “값을 어디에 저장하는가”와 “애플리케이션이 언제 새 값을 읽는가”를 분리해야 합니다. 여기에 외부 시스템이 이전 값과 새 값을 동시에 받아줄 수 있는지, 새 값을 검증할 방법이 있는지, 이전 값을 언제 폐기할지를 더해야 합니다. rotation은 파일 교체가 아니라 여러 참여자가 있는 작은 배포 프로토콜입니다.

## AWS Secrets Manager의 버전 흐름

AWS Secrets Manager는 하나의 secret에 여러 version을 둘 수 있고 staging label로 현재·이전·교체 중인 값을 구분합니다. 일반 조회는 `AWSCURRENT`를 반환합니다. rotation 중 새 값은 `AWSPENDING`으로 준비하고, 검증이 끝나면 `AWSCURRENT`를 새 version으로 옮기며 기존 값에는 `AWSPREVIOUS`가 붙습니다.

Lambda rotation의 기본 흐름은 네 단계입니다.

1. `createSecret`: 새 version을 만들고 `AWSPENDING`으로 저장한다.
2. `setSecret`: DB나 외부 서비스가 새 자격 증명을 허용하도록 변경한다.
3. `testSecret`: 새 version으로 실제 인증과 필요한 권한을 확인한다.
4. `finishSecret`: 새 version을 `AWSCURRENT`로 승격하고 이전 값을 `AWSPREVIOUS`로 남긴다.

이 흐름의 핵심은 `testSecret`이 성공하기 전에는 애플리케이션이 새 값을 반드시 써야 한다고 가정하지 않는 것입니다. version stage는 “어떤 값이 최신으로 간주되는가”를 표현하고, 애플리케이션 캐시와 connection pool은 별도의 전파 시간을 갖습니다.

## 무중단 교체의 네 가지 경계

### 1. 외부 시스템의 허용 범위

API key라면 공급자가 두 개의 유효한 key를 동시에 허용하는지 확인합니다. 가능하다면 새 key를 먼저 발급하고, 외부 서비스에 등록한 뒤 새 key로 health check와 대표 요청을 검증합니다. 그 다음 애플리케이션이 새 key를 읽도록 전환하고, 모든 인스턴스가 새 값을 사용한 뒤 이전 key를 폐기합니다.

DB 비밀번호는 서비스마다 전략이 다릅니다. AWS Secrets Manager의 single-user rotation은 열린 DB 연결을 끊지 않지만, 이후 새 연결은 새 credential을 사용합니다. 높은 가용성이 필요하면 alternating users처럼 두 사용자를 번갈아 갱신하는 전략을 검토할 수 있고, rotation 중에도 유효한 사용자 쌍을 남기는 방식이 됩니다. 실제 권한 모델과 클라이언트 동작을 확인하지 않고 전략을 복사하면 안 됩니다.

### 2. 애플리케이션 캐시

Secrets Manager를 요청마다 조회하면 비용·지연·rate limit 문제가 생길 수 있어 캐시가 필요합니다. 하지만 캐시 TTL이 rotation overlap보다 길면 새 값이 승격되어도 일부 인스턴스가 이전 값을 계속 사용합니다. 캐시 TTL과 강제 refresh 경로, refresh 실패 시 사용할 마지막 정상 값의 보존 시간을 명시해야 합니다.

간단한 애플리케이션 정책은 다음과 같습니다.

```text
정상 요청: 캐시된 AWSCURRENT 값을 사용
TTL 만료: 새 값을 조회하고 version id·loaded_at을 갱신
인증 실패: secret 값을 로그에 남기지 않고 한 번 강제 refresh
강제 refresh 후에도 실패: 제한된 재시도 후 오류를 반환하고 알림
```

인증 실패 때 무한 refresh를 허용하면 외부 API 장애가 Secrets Manager 호출 폭주로 번집니다. 강제 refresh는 한 요청 또는 한 refresh cycle당 한 번으로 제한하고, 동시 refresh에는 single-flight나 짧은 lock을 두는 편이 안전합니다.

### 3. 연결 풀과 프로세스 수명

HTTP client가 connection pool을 유지하면 secret을 새로 읽는 것만으로 이미 열린 연결의 인증 정보가 바뀌지는 않습니다. DB도 마찬가지로 기존 연결과 새 연결의 시점이 다를 수 있습니다. 따라서 refresh 구현에는 새 credential을 적용할 대상이 애플리케이션 변수만인지, 새 connection을 만들 때의 설정인지, 기존 pool을 drain하고 다시 만드는 작업까지 포함되는지를 적습니다.

무중단 전환에서는 보통 새 값을 적용한 뒤 새 연결을 만들 수 있는지 확인하고, 기존 연결은 정상 요청이 끝날 때까지 유지합니다. pool을 한 번에 비우면 reconnect storm이 생길 수 있으므로 최대 동시 reconnect 수, backoff, 전체 deadline을 정해야 합니다.

### 4. 이전 값의 폐기 시점

모든 인스턴스가 새 값을 읽었다고 판단할 수 있는 근거가 필요합니다. `AWSCURRENT`가 바뀌었다는 이벤트만으로는 충분하지 않습니다. 인스턴스별 secret version·loaded_at 메트릭이나 refresh 완료 비율을 확인하고, 최대 cache TTL·connection lifetime·배포 지연을 합친 overlap 시간을 기다린 뒤 이전 값을 폐기합니다.

외부 API가 두 key를 허용하지 않거나 이전 값을 즉시 폐기해야 하는 보안 사건이라면 무중단보다 차단 속도가 우선일 수 있습니다. 이 경우 예정된 rotation과 긴급 revoke 절차를 분리하고, 사용자가 겪을 인증 오류와 복구 순서를 runbook에 적어야 합니다.

## 실패를 줄이는 rotation 예시

```text
T0  AWSCURRENT=v1, 모든 Pod가 v1 사용
T1  AWSPENDING=v2 생성
T2  외부 API/DB에 v2 등록 또는 두 번째 사용자 생성
T3  v2로 인증·권한·대표 요청 테스트
T4  finishSecret으로 v2를 AWSCURRENT로 승격
T5  Pod 캐시 refresh와 새 connection 생성 비율 확인
T6  overlap 시간이 지난 뒤 v1 폐기
```

rotation 실패가 T2나 T3에서 발생하면 `AWSPENDING`이 남을 수 있습니다. 다음 rotation이 시작되지 않는다면 version stage와 rotation 로그를 확인하고, 실패한 pending version을 정리하는 절차를 따릅니다. rotation 함수는 `ClientRequestToken`을 사용해 같은 요청을 다시 받아도 같은 version을 확인하도록 설계해야 하며, 로그에는 secret value가 아닌 version id와 단계·소요 시간만 남겨야 합니다.

## 자주 하는 실수

첫 번째는 secret 저장 값을 바꾼 뒤 애플리케이션이 자동으로 새 값을 읽을 것이라고 가정하는 것입니다. 환경 변수와 Kubernetes Secret volume은 애플리케이션 설정 방식에 따라 reload 시점이 다릅니다. 실제 refresh가 없다면 rolling restart나 명시적인 reload endpoint가 필요하고, 그때 readiness와 connection draining도 함께 검증해야 합니다.

두 번째는 모든 Pod를 동시에 재시작하는 것입니다. 새 값의 인증이 확인되지 않은 상태에서 한 번에 연결을 끊으면, 실패한 새 연결이 복구 경로까지 막을 수 있습니다. canary 인스턴스에서 먼저 새 값을 적용하고, 인증 성공·오류율·refresh latency를 본 뒤 범위를 넓히는 편이 안전합니다.

세 번째는 rotation 함수 로그에 secret payload나 접속 문자열을 남기는 것입니다. AWS도 custom rotation function의 디버깅 로그가 민감 정보를 기록하지 않도록 주의하라고 안내합니다. CloudWatch 로그 접근 권한이 넓다면 값이 아닌 secret ARN, version stage, 오류 코드만 남깁니다.

네 번째는 이전 값을 너무 빨리 폐기하는 것입니다. cache, long-lived connection, batch worker, 장애 중인 오래된 Pod가 남아 있을 수 있습니다. 폐기 기준은 “rotation API가 성공했다”가 아니라 “이전 값을 쓰는 consumer가 없거나, 실패해도 복구 가능한가”여야 합니다.

## 언제 어떤 전략을 선택할까

- 두 credential을 동시에 허용할 수 있는 API key라면 새 값 발급 → 검증 → consumer 전환 → 이전 값 폐기 순서를 사용한다.
- DB처럼 연결 수명과 권한 모델이 중요한 자격 증명은 single-user와 alternating users의 차이, pool 재연결 방식을 먼저 확인한다.
- 외부 시스템이 한 값만 허용하면 overlap 대신 canary·drain·bounded retry로 전환 실패 시간을 제한한다.
- 자동 refresh가 없는 단순 서비스라면 무중단 rotation보다 안전한 rolling restart와 명확한 maintenance window가 더 현실적일 수 있다.

## 운영에서 볼 것

- secret version stage의 `AWSCURRENT`, `AWSPENDING`, `AWSPREVIOUS` 변화
- rotation 단계별 성공·실패·소요 시간과 pending version 잔류
- 인스턴스별 loaded secret version, cache age, refresh 실패 수
- 외부 API 401·403, DB authentication failure, 새 connection 생성 실패
- connection pool active·pending·reconnect와 배포 중 readiness/traffic 변화
- CloudTrail·CloudWatch rotation 이벤트와 runbook 실행 기록

시크릿 값 자체는 절대 메트릭 label이나 로그에 넣지 않습니다. 대신 version id, provider 응답 코드, consumer 그룹, refresh 시각을 남기면 값 노출 없이 전파 상태를 확인할 수 있습니다.

## 정리

시크릿 rotation은 저장된 문자열을 바꾸는 일이 아니라 외부 허용 범위·캐시·연결 풀·폐기 시점을 조정하는 프로토콜이다.
새 값을 만들고 검증한 뒤 consumer를 전환하며, 이전 값은 cache·connection 수명을 고려한 overlap 뒤 폐기해야 한다.
AWS Secrets Manager의 `AWSPENDING`·`AWSCURRENT`·`AWSPREVIOUS`와 rotation 4단계를 기준으로 실패 지점을 관측하자.
무중단이 항상 우선은 아니며, 단일 credential·긴급 revoke·refresh 미지원 서비스에서는 안전한 재시작 전략을 선택해야 한다.

## 참고한 공식 문서

- [AWS Secrets Manager - Rotate secrets](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets.html)
- [AWS Secrets Manager - Lambda rotation functions](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotate-secrets_lambda-functions.html)
- [AWS Secrets Manager - Lambda function rotation strategies](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotation-strategy.html)
- [AWS Secrets Manager - Best practices](https://docs.aws.amazon.com/secretsmanager/latest/userguide/best-practices.html)
