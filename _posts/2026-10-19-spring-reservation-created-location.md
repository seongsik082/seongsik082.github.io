---
title: "예약 생성 API에서 200 OK 대신 201 Created를 고려하는 이유"
date: 2026-10-19 08:55:00 +0900
tags: [Spring, HTTP, REST API, Backend]
excerpt: "예약 생성 API 예제로 200 OK와 201 Created의 의미, Location 헤더가 가리키는 새 리소스, Spring ResponseEntity.created를 사용할 기준을 초급 수준에서 설명한다."
---

새 예약이 만들어졌다는 사실과 조회 위치를 응답에 담는 방법

**대상 독자: Java 문법과 간단한 Spring CRUD를 막 익힌 개발자**

예약 생성 API를 만들면 저장에 성공했으니 일단 `200 OK`를 반환하고 싶어진다. 동작은 할 수 있다. 하지만 API를 사용하는 쪽에서는 “요청은 처리됐는가”, “새 예약이 실제로 생겼는가”, “그 예약을 어디서 다시 조회하는가”를 구분할 수 있으면 더 편하다. 이 글은 예약 하나를 만드는 POST 요청을 기준으로 `201 Created`와 `Location` 헤더를 쉽게 설명한다.

핵심은 모든 성공 응답을 201로 바꾸는 것이 아니다. 서버가 요청을 받아 실제로 새 리소스를 만들었을 때, 그 사실을 HTTP 응답에도 드러내는 방법을 배우는 것이다. 아직 처리가 끝나지 않았거나 기존 예약을 수정한 경우에는 다른 선택이 더 맞을 수 있다.

## 1. 오늘의 주제

사용자가 특정 시간의 상담을 예약한다고 하자. 클라이언트는 `POST /reservations`에 날짜와 시간을 보낸다. 서버가 검증을 통과하고 데이터베이스에 새 예약을 저장했다면, 새 예약에는 예를 들어 42라는 ID가 생긴다.

이때 `201 Created`는 새 리소스가 만들어졌다는 성공 상태 코드다. `Location` 헤더는 그 새 예약을 찾을 수 있는 주소를 알려 준다. 예를 들어 `Location: /reservations/42`처럼 응답에 넣을 수 있다. 이 글을 읽은 뒤에는 “새로 만들었는가”와 “단순히 성공했는가”를 구분해 응답을 선택할 수 있다.

여기서 리소스는 API가 다루는 대상이다. 이 글에서는 예약 한 건이 리소스다. 파일 업로드 완료 알림이나 계산 요청처럼 즉시 예약 행을 만들지 않는 작업은 같은 기준을 바로 적용하면 안 된다.

## 2. 핵심 개념

`200 OK`는 요청이 성공적으로 처리되었다는 넓은 뜻의 상태 코드다. 조회 성공, 수정 성공, 계산 결과 반환처럼 여러 상황에 사용할 수 있다. 응답 본문에 필요한 결과를 담아 돌려줄 때 자주 보인다.

`201 Created`는 서버가 요청을 처리하면서 새 리소스를 만들었다는 뜻이다. 예약 생성처럼 이전에는 없던 예약 한 건이 생겼을 때 의도가 분명하다. 생성된 리소스의 표현을 응답 본문에 넣을 수도 있고, 넣지 않을 수도 있다.

`Location`은 응답 헤더다. 새 리소스의 주소를 알려 주는 데 사용한다. 클라이언트가 응답 본문의 ID를 조합하지 않아도, 다음 조회 주소를 알 수 있다. 다만 Location이 있다고 해서 그 주소가 영구적이라는 뜻은 아니다. 현재 API가 제공하는 리소스 위치라는 계약으로 이해하면 된다.

## 3. 내부 동작 원리

예약 생성 요청은 다음 순서로 흐른다.

1. 클라이언트가 날짜와 시간을 담아 `POST /reservations` 요청을 보낸다.
2. Controller는 JSON을 요청 DTO로 받고 필수값을 확인한다.
3. Service는 예약 가능 여부를 확인하고 새 `Reservation`을 저장한다.
4. 저장 결과에 생성된 예약 ID가 생긴다.
5. Controller는 ID로 Location을 만들고 `201 Created` 응답을 보낸다.

중요한 지점은 4번이다. `201 Created`는 단순히 Service 메서드를 호출했다는 표시가 아니다. 새 예약이 만들어졌다는 결과를 응답하는 것이다. 저장 전에 응답을 만들거나, 실패했는데도 201을 보내면 클라이언트는 실제 상태와 다른 정보를 받는다.

Location은 프런트엔드 화면을 이동시키는 명령이 아니다. 서버가 “이 응답으로 생성된 예약은 이 주소로 식별할 수 있다”고 알려 주는 HTTP 정보다. 화면이 이 헤더를 사용할지, 응답 본문의 ID를 사용할지는 클라이언트 구현의 선택이다. 서버는 둘의 값이 서로 어긋나지 않게 유지해야 한다.

## 4. 실제 코드

아래 코드는 예약 생성 결과에 예약 ID가 들어온다고 가정한다. `ResponseEntity.created`는 201 상태와 Location 헤더를 만드는 Spring 도구다.

```java
@RestController
@RequestMapping("/reservations")
@RequiredArgsConstructor
public class ReservationController {
    private final ReservationService reservationService;

    @PostMapping
    public ResponseEntity<ReservationResponse> create(
            @Valid @RequestBody CreateReservationRequest request) {

        ReservationResponse created = reservationService.create(request);
        URI location = URI.create("/reservations/" + created.id());

        return ResponseEntity.created(location).body(created);
    }
}
```

`reservationService.create`가 성공한 뒤에만 `created.id()`를 사용한다. 그래서 Location과 응답 본문의 ID가 같은 예약을 가리킨다. `ResponseEntity.created(location)`은 응답 상태를 201로 만들고, `body(created)`는 새 예약의 번호와 시간 같은 정보를 응답 본문에 담는다.

학습용 코드에서는 URI 문자열을 직접 만들었다. 실제 프로젝트에서는 API의 경로 규칙을 한 곳에 모으거나 URI 생성 도구를 사용해 주소 조합 실수를 줄일 수 있다. 중요한 것은 문자열을 만드는 방식보다, 새 리소스의 ID가 확정된 뒤 Location을 만든다는 순서다.

## 5. 실제 서비스 적용

작은 예약 서비스에서 새 예약 생성은 POST와 201을 사용하는 좋은 후보다. 생성 뒤 화면이 예약 상세로 이동해야 한다면 Location과 응답 본문의 예약 ID가 모두 도움이 된다. 반면 기존 예약의 시간을 바꾸는 요청은 새 리소스를 만드는 일이 아니라 수정이므로, 같은 201 규칙을 적용하지 않는다.

예약 요청이 늘어날 때 201 자체가 중복 예약을 막아 주지는 않는다. 같은 사용자가 버튼을 두 번 눌러도 두 요청이 들어올 수 있다. 이 글의 상태 코드는 응답의 의미를 정하는 도구이고, 중복 요청 방지나 시간대 충돌 검사는 Service와 데이터 규칙에서 따로 처리해야 한다.

처음 볼 테스트는 정상 생성 요청의 상태가 201인지, `Location`이 생성된 예약 ID를 포함하는지다. 이후 예약 상세 조회가 같은 주소에서 가능한지도 확인한다. 로그에서 201이 보이는데 조회가 안 된다면, 상태 코드보다 저장 결과와 Location 조합이 같은 ID를 사용하는지 먼저 살핀다.

## 6. 흔히 발생하는 문제

### 1) 새 예약을 만들고도 항상 200만 반환하는 경우

현상은 클라이언트가 성공은 알지만 새 예약 생성과 일반 성공을 구분하기 어려운 것이다. 원인은 응답 상태 코드에 생성 결과를 드러내지 않았기 때문이다. 첫 확인 지점은 POST 생성 API의 응답 상태다. 새 리소스가 실제로 만들어졌다면 201과 Location을 검토한다.

### 2) 저장 전에 Location을 만드는 경우

현상은 응답에 있는 예약 주소와 실제 저장된 예약 ID가 다르거나, 저장 실패인데도 201이 나가는 것이다. 원인은 생성 결과가 확정되기 전에 응답을 조립했기 때문이다. 첫 확인 지점은 Service 호출과 URI 생성 순서다. 저장 결과의 ID를 받은 뒤 Location을 만든다.

### 3) 모든 POST 요청에 201을 쓰는 경우

현상은 비동기 접수나 단순 실행 요청에도 새 예약이 생긴 것처럼 보이는 것이다. 원인은 POST와 Created를 같은 뜻으로 본 데 있다. 첫 확인 지점은 요청 뒤에 새 리소스가 즉시 존재하는지다. 처리가 나중에 끝나는 작업이나 기존 상태 변경은 200, 202 등 다른 응답을 검토한다.

## 7. 기술 선택의 Trade-off

`201 Created`와 Location의 장점은 API 계약이 분명해진다는 점이다. 응답만 보고도 새 예약이 만들어졌고, 조회할 주소가 있다는 것을 알 수 있다. 생성 API가 많아져도 클라이언트가 같은 방식으로 후속 조회를 구성하기 쉽다.

단점은 생성된 리소스의 위치와 ID를 정확히 관리해야 한다는 점이다. 주소 규칙을 자주 바꾸거나 저장이 비동기로 끝나는 API라면 단순한 201 규칙을 적용하기 어렵다. 또한 201을 반환해도 중복 요청, 예약 가능 시간, 권한 검사는 자동으로 해결되지 않는다.

다음 네 단계로 선택하면 충분하다.

1. 요청이 끝났을 때 새 예약 리소스가 실제로 만들어졌는지 확인한다.
2. 생성됐다면 저장 결과의 ID를 기준으로 Location을 만든다.
3. 응답 본문과 Location이 같은 예약을 가리키는지 테스트한다.
4. 비동기 접수나 기존 예약 수정이라면 201 대신 현재 결과에 맞는 상태 코드를 고른다.

### 참고한 공식 문서

- [RFC 9110 - 201 Created](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.3.2) — 201 응답이 하나 이상의 새 리소스가 생성되었음을 나타내며 Location이 생성 리소스를 식별할 수 있다는 규칙을 확인했다.
- [Spring ResponseEntity API](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/http/ResponseEntity.BodyBuilder.html) — `ResponseEntity.created(URI)`로 201 응답과 Location 헤더를 만드는 Spring API를 확인했다.
