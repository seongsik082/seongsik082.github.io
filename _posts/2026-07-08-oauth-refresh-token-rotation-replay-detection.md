---
title: "Refresh Token Rotation을 세션 연장 기능으로만 보면 탈취 재사용을 놓치는 이유"
date: 2026-07-08 08:56:00 +0900
tags: [Security, OAuth2, Backend]
excerpt: "Refresh token rotation의 핵심은 사용자를 오래 로그인시키는 것이 아니라, 탈취된 refresh token이 다시 쓰였을 때 감지하고 같은 grant의 활성 토큰을 끊는 운영 규칙입니다."
---

## 문제 상황

모바일 앱이나 SPA에서 access token 만료 시간을 짧게 잡으면 사용자는 자주 다시 로그인해야 한다. 그래서 refresh token을 발급해 access token을 다시 받게 만든다. 여기까지만 보면 refresh token은 "세션 연장용 긴 토큰"처럼 보인다.

문제는 이 긴 토큰이 탈취되었을 때다. 공격자가 refresh token을 복사해 두고, 정상 사용자와 번갈아 token endpoint를 호출하면 서버는 둘 중 누가 진짜인지 바로 알기 어렵다. access token이 짧아도 공격자는 refresh token으로 계속 새 access token을 만들 수 있다. 그래서 refresh token은 access token보다 더 조심해서 다뤄야 한다.

RFC 9700은 public client의 refresh token replay를 감지하기 위해 sender-constrained refresh token 또는 refresh token rotation 같은 방법을 사용해야 한다고 정리한다. 여기서 public client는 비밀 값을 안전하게 숨기기 어려운 클라이언트다. 브라우저 SPA나 네이티브 앱처럼 사용자의 기기에서 실행되는 앱을 떠올리면 된다.

## 핵심 개념

Refresh token rotation은 refresh 요청이 성공할 때마다 새 refresh token을 발급하고, 이전 refresh token은 무효화하는 방식이다. 정상 클라이언트는 항상 최신 refresh token 하나만 보관한다. 이전 토큰이 다시 들어오면 서버는 "이미 사용된 토큰이 재사용되었다"는 신호로 볼 수 있다.

중요한 점은 rotation이 탈취를 완전히 예방하는 기능은 아니라는 것이다. 이미 복사된 토큰이 먼저 사용되면 공격자가 새 토큰을 받을 수도 있다. rotation의 실무 가치는 재사용을 감지하고, 같은 authorization grant에 연결된 활성 refresh token을 끊어 피해 확산을 막는 데 있다. authorization grant는 사용자가 특정 클라이언트에 허용한 권한 묶음이라고 이해하면 된다.

따라서 refresh token rotation은 단순히 `refresh_token` 컬럼 하나를 새 값으로 덮어쓰는 작업이 아니다. 토큰의 계보, 사용 여부, grant 단위 revocation, 재사용 감지 로그가 함께 있어야 운영 가능한 보안 장치가 된다.

## 데이터 모델로 보기

간단한 모델은 다음처럼 잡을 수 있다.

```sql
CREATE TABLE oauth_grant (
    id uuid PRIMARY KEY,
    user_id bigint NOT NULL,
    client_id varchar(100) NOT NULL,
    scope text NOT NULL,
    revoked_at timestamp NULL,
    created_at timestamp NOT NULL
);

CREATE TABLE refresh_token (
    id uuid PRIMARY KEY,
    grant_id uuid NOT NULL REFERENCES oauth_grant(id),
    token_hash varchar(255) NOT NULL UNIQUE,
    previous_token_id uuid NULL,
    used_at timestamp NULL,
    revoked_at timestamp NULL,
    expires_at timestamp NOT NULL,
    created_at timestamp NOT NULL
);
```

토큰 원문은 DB에 저장하지 않고 hash만 저장한다. DB가 유출되었을 때 refresh token 원문이 바로 재사용되는 일을 줄이기 위해서다. refresh 요청이 오면 서버는 원문을 hash로 바꿔 현재 토큰을 찾고, 상태를 검사한 뒤 새 토큰을 만든다.

```text
1. 요청 refresh_token의 hash를 찾는다
2. grant가 revoked 상태인지 확인한다
3. token이 만료, 폐기, 이미 사용 상태인지 확인한다
4. 이미 사용된 token이면 replay로 판단하고 grant를 revoke한다
5. 정상 token이면 used_at을 기록하고 새 refresh token을 발급한다
6. 새 token은 previous_token_id로 직전 token을 가리킨다
```

이 흐름은 반드시 하나의 트랜잭션 안에서 처리해야 한다. 같은 refresh token으로 동시에 두 요청이 들어오면 둘 다 정상으로 통과해서는 안 된다. `token_hash`를 기준으로 row lock을 잡거나, 상태 전이를 조건부 update로 처리해야 한다.

```sql
UPDATE refresh_token
SET used_at = now()
WHERE token_hash = :hash
  AND used_at IS NULL
  AND revoked_at IS NULL
  AND expires_at > now();
```

이 update의 영향 row 수가 1이면 정상 사용이다. 0이면 이미 사용되었거나, 만료되었거나, 폐기된 토큰이다. 이때 단순히 `invalid_grant`만 돌려주고 끝내면 공격 신호를 놓친다. 특히 이미 사용된 토큰이라면 같은 grant의 active token을 revoke하고 보안 이벤트를 남기는 쪽이 안전하다.

## 자주 하는 실수

첫 번째 실수는 refresh token을 매번 새로 발급하면서도 이전 토큰을 계속 허용하는 것이다. 이렇게 하면 이름만 rotation이고 실제로는 다중 유효 토큰 목록이 된다. 사용자가 여러 기기를 쓰는 경우를 지원하려면 기기별 grant나 token family를 나누어야지, 같은 grant에서 과거 토큰을 무기한 허용하면 replay 감지가 어려워진다.

두 번째 실수는 refresh token 만료 시간을 너무 길게 잡고 비활성 만료를 두지 않는 것이다. RFC 9700은 refresh token이 일정 기간 사용되지 않았다면 만료될 필요가 있다고 설명한다. 서비스 정책에 따라 값은 달라질 수 있지만, "한 번 로그인하면 영구 refresh 가능"은 사고 대응을 어렵게 만든다.

세 번째 실수는 로그에 refresh token 원문을 남기는 것이다. 인증 실패 로그, API gateway access log, 예외 메시지에 토큰이 찍히면 보안 장치가 오히려 유출 경로가 된다. token id, grant id, client id, user id, 실패 이유 정도만 남기고 원문은 남기지 않는 규칙이 필요하다.

## 언제 적용하고 언제 피할까

Refresh token rotation은 public client, 장기 로그인, access token 짧은 만료, 탈취 감지 요구가 있는 서비스에 잘 맞는다. 모바일 앱, 브라우저 기반 클라이언트, 여러 네트워크 환경에서 쓰이는 소비자 서비스가 대표적이다. 사용자가 다시 로그인해야 하는 비용이 크고, 동시에 탈취 대응도 필요하다면 rotation은 현실적인 선택이다.

반대로 서버 간 통신처럼 confidential client가 강한 client authentication을 수행하고, sender-constrained token을 안정적으로 쓸 수 있다면 rotation만이 답은 아니다. 또 토큰 저장소의 일관성을 보장하기 어렵거나, refresh 요청이 매우 많아 DB row lock 경합이 커지는 구조라면 모델을 먼저 정리해야 한다. rotation은 상태 저장이 필요한 보안 기능이므로 완전한 stateless JWT 발급 방식과는 잘 맞지 않는다.

실무 판단 기준은 "이전 refresh token이 다시 들어왔을 때 무엇을 할 것인가"다. 이 질문에 대한 답이 없다면 rotation을 도입한 것이 아니라 토큰 값을 자주 바꾸는 기능만 만든 것이다.

## 운영에서 볼 것

운영 지표는 인증 성공률보다 재사용 감지와 revocation 흐름을 중심으로 봐야 한다. refresh token replay 감지 수, grant revoke 수, `invalid_grant` 비율, token endpoint p95 지연, row lock wait, 사용자 재로그인 증가율을 확인한다.

로그 예시는 다음처럼 남길 수 있다.

```text
event=refresh_token_rotated grant_id=7f... client_id=mobile-app token_id=91...
event=refresh_token_replay_detected grant_id=7f... client_id=mobile-app old_token_id=88...
event=oauth_grant_revoked grant_id=7f... reason=refresh_token_reuse
```

장애 대응에서는 replay 감지가 갑자기 늘었는지, 특정 client 버전에서 동시에 refresh 요청을 두 번 보내는 버그가 있는지, 네트워크 재시도 때문에 같은 refresh token을 병렬로 재사용하는지 구분해야 한다. 모든 replay가 공격은 아니지만, 모든 replay를 단순 클라이언트 버그로 취급해도 안 된다.

## 정리

Refresh token rotation은 로그인 유지 기능이 아니라 refresh token 재사용을 감지하는 보안 장치다. 성공할 때마다 새 토큰을 주고 이전 토큰을 무효화하며, 이전 토큰이 다시 들어오면 같은 grant의 활성 토큰을 끊는 규칙까지 있어야 한다. token 원문 저장과 로그 노출을 피하고, 동시 refresh 요청을 트랜잭션으로 제어해야 실무에서 안전하게 운영할 수 있다.

참고한 공식 문서:

- [RFC 9700 - Best Current Practice for OAuth 2.0 Security](https://www.rfc-editor.org/rfc/rfc9700.html)
- [RFC 6749 - The OAuth 2.0 Authorization Framework](https://datatracker.ietf.org/doc/html/rfc6749)
