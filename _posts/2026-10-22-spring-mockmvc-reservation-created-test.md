---
title: "예약 생성 API 테스트에서 201 Created와 Location을 함께 확인하는 이유"
date: 2026-10-22 08:55:00 +0900
tags: [Spring, Testing, HTTP, Backend]
excerpt: "예약 생성 API를 MockMvc로 테스트하는 예제로 201 Created, Location 헤더, 응답 본문의 예약 ID를 함께 검증해야 하는 이유와 초급 개발자가 먼저 확인할 기준을 설명한다."
---

저장됐다는 말만 믿지 않고 HTTP 응답의 약속까지 확인하기

**대상 독자: Java 문법과 간단한 Spring CRUD를 막 익힌 개발자**

예약 생성 기능을 만들고 Controller 테스트를 작성할 때 `status().isOk()`만 넣기 쉽다. 테스트가 통과하면 안심할 수 있다. 하지만 새 예약을 만드는 API라면 성공했다는 사실만큼, 새 예약이 생성됐다는 HTTP 응답의 의미도 중요하다. 이 글은 예약 생성 요청 하나를 MockMvc로 검사하면서 `201 Created`, `Location` 헤더, 응답 본문의 예약 ID를 함께 확인하는 이유를 설명한다.

월요일 글에서 새 리소스가 만들어졌을 때 `201 Created`를 고려하는 방법을 살폈다. 오늘은 그 약속이 코드 변경 뒤에도 지켜지는지 테스트로 고정한다. 테스트는 특별한 고급 기능이 아니라, Controller가 클라이언트에게 하겠다고 약속한 응답을 자동으로 확인하는 안전망이다.

## 1. 오늘의 주제

예약 화면에서 사용자가 날짜와 시간을 고르고 생성 버튼을 누른다고 하자. 서버는 `POST /reservations` 요청을 받아 새 예약을 저장한다. 저장된 예약 번호가 42라면, 응답은 `201 Created`와 `Location: /reservations/42`를 줄 수 있다.

그런데 나중에 Controller 코드를 고치면서 상태 코드가 200으로 바뀌거나, Location이 `/reservations/null`처럼 잘못 만들어질 수 있다. 화면에서는 응답 본문만 쓰고 있어서 바로 드러나지 않을 수도 있다. 이때 테스트가 상태 코드와 헤더를 함께 확인하면 API의 중요한 약속이 깨진 순간을 알려 준다.

이 주제는 `@PostMapping`으로 생성 기능을 만든 다음 배우기 좋다. 글을 읽고 나면 새 리소스를 만드는 API에서 무엇을 테스트해야 하는지, 그리고 응답 본문만 확인하면 부족한 이유를 판단할 수 있다.

## 2. 핵심 개념

MockMvc는 실제 웹 서버 포트를 열지 않고 Spring MVC 요청과 응답을 테스트하는 도구다. 테스트 코드에서 POST 요청을 보내고, Controller가 만든 상태 코드·헤더·본문을 확인할 수 있다.

상태 코드는 요청 처리 결과를 짧게 알려 주는 숫자다. `201 Created`는 서버가 새 리소스를 만들었다는 뜻이다. 예약을 새로 저장했다면 201을 기대할 수 있다. 반대로 기존 예약 시간을 수정했거나 새 예약이 아직 만들어지지 않았다면 무조건 201을 기대하면 안 된다.

`Location`은 응답 헤더다. 헤더는 본문 밖에 담기는 HTTP 정보다. 예약 생성 응답의 `Location: /reservations/42`는 방금 만든 예약을 다시 찾을 수 있는 주소를 가리킨다. 응답 본문의 `id`와 Location 끝의 번호는 같은 예약을 가리켜야 한다.

## 3. 내부 동작 원리

예약 생성 테스트의 흐름은 다섯 단계다.

1. 테스트가 JSON 본문을 넣어 `POST /reservations` 요청을 만든다.
2. MockMvc가 Spring MVC에 요청을 전달하고 Controller 메서드를 실행한다.
3. Service가 예약을 저장했다고 가정한 결과로 예약 ID를 돌려준다.
4. Controller는 그 ID로 Location을 만들고 201 응답과 응답 본문을 조립한다.
5. 테스트가 상태 코드, Location, 본문의 ID를 차례대로 비교한다.

여기서 테스트가 데이터베이스 저장 자체를 증명하는 것은 아니다. MockMvc Controller 테스트는 “Controller가 Service 결과를 받아 올바른 HTTP 응답을 만들었는가”에 집중한다. 저장 규칙은 Service 테스트나 통합 테스트에서 별도로 확인한다. 한 테스트에 모든 것을 넣으면 실패 원인을 찾기 어려워진다.

세 값은 서로 연결돼 있다. Service가 반환한 ID가 42인데 Controller가 Location을 41로 만들면, 상태 코드만 보는 테스트는 통과할 수 있다. 반대로 ID, 헤더, 상태 코드를 함께 확인하면 주소 조합 실수도 발견할 수 있다.

## 4. 실제 코드

아래 예시는 `reservationService.create`가 ID가 42인 예약 응답을 돌려준다고 설정한 Controller 테스트다. JSON 본문은 학습용 예약 요청이다.

```java
@WebMvcTest(ReservationController.class)
class ReservationControllerTest {
    @Autowired MockMvc mockMvc;
    @MockitoBean ReservationService reservationService;

    @Test
    void 예약을_만들면_201과_조회_주소를_반환한다() throws Exception {
        given(reservationService.create(any()))
                .willReturn(new ReservationResponse(42L, "2026-11-03", "10:00"));

        mockMvc.perform(post("/reservations")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                            {"date":"2026-11-03", "time":"10:00"}
                            """))
                .andExpect(status().isCreated())
                .andExpect(header().string("Location", "/reservations/42"))
                .andExpect(jsonPath("$.id").value(42));
    }
}
```

`@WebMvcTest`는 Controller와 Spring MVC 동작을 중심으로 테스트 환경을 준비한다. `@MockitoBean`으로 만든 Service는 진짜 데이터베이스에 저장하지 않는다. 그래서 이 테스트는 예약 가능 시간이나 SQL을 확인하는 대신, Controller 응답을 빠르게 확인한다.

첫 번째 `andExpect`는 새 예약이 만들어졌다는 약속을 확인한다. 두 번째는 조회 주소가 정확히 조합됐는지 확인한다. 마지막은 JSON 본문의 `id`가 42인지 확인한다. ID를 바꾸거나 Controller의 URI 조합을 잘못 고치면 어느 약속이 깨졌는지 실패 메시지에서 바로 알 수 있다.

코드의 문자열을 그대로 복사하기보다 프로젝트의 예약 요청 DTO 필드 이름에 맞춰 바꿔야 한다. 특히 실제 API가 `/api/reservations`처럼 접두어를 사용한다면 Location 기대값도 같은 경로 규칙을 따라야 한다.

## 5. 실제 서비스 적용

작은 예약 서비스라면 생성 Controller 테스트를 먼저 작성한 뒤, Service 테스트에서 “같은 시간에 예약할 수 있는가” 같은 업무 규칙을 확인한다. Controller 테스트의 책임은 HTTP 계약이고, Service 테스트의 책임은 예약 규칙이다. 이렇게 나누면 Controller 경로를 바꿨을 때와 예약 규칙을 바꿨을 때 무엇이 깨졌는지 구분하기 쉽다.

입력이 늘어나도 이 테스트가 서버 부하를 측정해 주지는 않는다. 이 테스트는 빠르게 자주 실행하는 단위에 가깝다. 실제 저장과 조회가 이어지는지 확인해야 한다면 별도의 통합 테스트를 둔다. 하지만 API를 처음 만들 때는 201, Location, 본문 ID라는 세 가지 약속을 먼저 고정하는 편이 좋다.

테스트가 실패하면 첫 번째로 Controller의 `ResponseEntity` 반환 부분을 본다. 다음으로 Service가 돌려주는 응답의 ID와 URI 문자열 조합을 비교한다. 로그보다 테스트 실패 메시지에서 기대한 상태 코드와 실제 상태 코드를 먼저 보는 편이 빠르다.

## 6. 흔히 발생하는 문제

### 1) 상태 코드만 확인하는 경우

현상은 테스트가 201인지만 보고 통과하지만 Location이 없거나 잘못된 주소여도 알아채지 못하는 것이다. 원인은 생성 API의 약속을 상태 코드 하나로만 봤기 때문이다. 첫 확인 지점은 `andExpect` 목록이다. 새 리소스 조회 주소를 응답에 제공한다면 `header().string` 검사도 추가한다.

### 2) Location에 요청 값이나 임의 번호를 쓰는 경우

현상은 응답 본문의 예약 ID와 Location이 서로 다르게 보이는 것이다. 원인은 저장 뒤 받은 ID 대신 요청 DTO의 값이나 임시 번호로 주소를 만든 데 있다. 첫 확인 지점은 Controller에서 URI를 만드는 줄이다. Service의 생성 결과 ID 하나를 본문과 Location에 함께 사용한다.

### 3) Controller 테스트로 저장 규칙까지 모두 확인하려는 경우

현상은 테스트 설정이 복잡해지고, 실패해도 HTTP 응답 문제인지 예약 규칙 문제인지 알기 어려운 것이다. 원인은 테스트의 책임을 나누지 않았기 때문이다. 첫 확인 지점은 MockMvc 테스트에 데이터베이스 상태를 너무 많이 준비하고 있는지다. HTTP 응답은 Controller 테스트로, 실제 저장 규칙은 Service 또는 통합 테스트로 분리한다.

## 7. 기술 선택의 Trade-off

MockMvc로 Controller를 테스트하면 실제 브라우저나 서버 포트를 열지 않고 HTTP 응답을 확인할 수 있다. 그래서 경로, 상태 코드, 헤더, JSON 구조가 바뀌었을 때 빠르게 알 수 있다. 예약 생성 API처럼 프런트엔드와 약속할 값이 분명한 기능에 특히 잘 맞는다.

대신 이 테스트만으로 데이터베이스에 예약이 저장됐다고 말할 수는 없다. Service를 가짜로 바꿨기 때문이다. SQL, 트랜잭션, 실제 요청 변환까지 검증해야 하는 상황이라면 통합 테스트가 필요하다. 모든 Controller 테스트를 통합 테스트로 만들면 실행 시간이 길어지고 실패 원인을 좁히기 어려워질 수 있다.

다음 순서로 선택하면 된다.

1. 새 리소스를 만드는 API인지 확인하고, 맞다면 201과 Location이라는 응답 약속을 정한다.
2. MockMvc 테스트로 상태 코드, Location, 응답 본문의 핵심 값을 확인한다.
3. 예약 가능 시간과 저장 결과는 Service 또는 통합 테스트에서 따로 확인한다.
4. 경로 규칙을 바꿀 때는 Location 기대값도 함께 수정해 API 계약이 어긋나지 않게 한다.

### 참고한 공식 문서

- [RFC 9110 - 201 Created](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.3.2) — 201 응답이 새 리소스 생성 결과를 나타내고 Location이 생성된 리소스를 식별할 수 있다는 규칙을 확인했다.
- [Spring Framework - MockMvc 결과 기대값](https://docs.spring.io/spring-framework/reference/testing/mockmvc/hamcrest/expectations.html) — `status`, `header`, `jsonPath`로 HTTP 응답을 확인하는 MockMvc 사용 방식을 확인했다.
