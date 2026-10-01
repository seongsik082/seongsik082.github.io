---
title: "예약 취소 권한에서 Long ID를 ==로 비교하면 생기는 일"
date: 2026-10-01 08:55:00 +0900
tags: [Java, Spring, Security, Backend]
excerpt: "예약 취소 권한 확인 예제로 Long과 long의 차이, Long ID를 == 대신 Objects.equals로 비교해야 하는 이유, null과 인증 값을 다루는 기준을 초급 수준에서 설명한다."
---

# 예약 취소 권한에서 Long ID를 ==로 비교하면 생기는 일

예약 ID가 같은데도 취소 권한이 없다고 나오는 이유

**대상 독자: Java 문법과 간단한 Spring CRUD를 막 익힌 개발자**

예약 취소 기능을 만들 때는 예약의 주인인지 확인해야 한다. 이때 데이터베이스에서 읽은 회원 ID와 로그인한 회원 ID가 둘 다 `Long`이면, 숫자가 같아 보여도 `==` 비교가 다르게 동작할 수 있다. 이 글은 예약·출석 서비스의 취소 요청 하나를 따라가며 그 이유를 설명한다. 핵심은 숫자 자체가 아니라, Java가 두 `Long`을 무엇으로 비교하는지 구분하는 것이다.

## 1. 오늘의 주제

예약 서비스에는 보통 “내 예약만 취소할 수 있다”는 규칙이 있다. 예약 번호가 `15`인 예약을 찾았다면, 그 예약을 만든 회원의 ID와 현재 로그인한 회원의 ID가 같은지 확인해야 한다. 이 비교가 틀리면 본인 예약을 거절하거나, 반대로 다른 사람의 요청을 허용하는 코드가 생길 수 있다.

Java 문법을 배운 뒤 Spring에서 엔티티 ID를 다루기 시작하는 시점에 꼭 만나는 문제다. 화면에서 온 값과 데이터베이스에서 온 값은 모두 숫자처럼 보인다. 하지만 JPA 엔티티의 ID는 보통 `Long` 타입이다. 이 글을 읽은 뒤에는 예약 취소 코드에서 `==`를 발견했을 때 바꿔야 하는지 판단할 수 있다.

여기서 다루는 것은 학습용 예약·출석 서비스의 권한 확인이다. HTTP 상태 코드나 로그인 방식은 프로젝트마다 다를 수 있지만, 비교 기준은 어느 서비스에서나 같다.

## 2. 핵심 개념

먼저 `long`과 `Long`은 이름이 비슷하지만 같은 종류가 아니다. `long`은 숫자 값을 바로 담는 기본형이다. `Long`은 `long` 값을 감싼 객체다. 객체는 값 외에도 자신이 만들어진 위치를 가리키는 정보, 즉 참조를 가진다.

`==`는 기본형끼리 비교하면 숫자 값을 비교한다. 따라서 `long a = 15L; long b = 15L;`에서 `a == b`는 자연스럽게 `true`다. 반면 `Long` 객체 두 개를 `==`로 비교하면, 기본적으로 두 변수가 같은 객체를 가리키는지 비교한다. 숫자가 같다는 뜻과 같은 객체라는 뜻은 다르다.

`Objects.equals(a, b)`는 두 객체의 값을 비교하는 도구다. 둘 다 `Long`이면 `Long`이 가진 숫자 값을 비교한다. 한쪽이 `null`이어도 예외를 바로 내지 않고 비교 결과를 돌려준다. 예약 ID처럼 데이터베이스와 요청 처리 사이를 오가는 객체에는 이 방식이 읽기 쉽고 안전하다.

## 3. 내부 동작 원리

예약 취소 요청에서 비교가 일어나는 순서는 다음처럼 단순하다.

1. 클라이언트가 예약 번호를 담아 취소 요청을 보낸다.
2. 서버는 로그인 정보에서 현재 회원 ID를 얻는다. 이 ID는 요청 본문이 아니라 인증이 끝난 서버 쪽 정보여야 한다.
3. 서비스는 예약 번호로 예약을 조회한다. 예약이 없으면 비교를 진행하지 않고 예외를 처리한다.
4. 조회한 예약의 `memberId`와 현재 회원 ID를 비교한다.
5. 값이 같으면 상태를 취소로 바꾸고, 다르면 취소를 거절한다.

문제는 4번이다. 데이터베이스에서 읽은 `reservation.getMemberId()`와 인증 과정에서 얻은 `currentMemberId`는 같은 숫자를 담아도 서로 다른 `Long` 객체일 수 있다. 이때 `==`는 “둘 다 15인가?”가 아니라 “둘이 같은 객체인가?”를 묻는다. 그래서 코드가 실행된 경로나 객체가 만들어진 방식에 따라 결과가 달라지는 것처럼 보일 수 있다.

`Long`을 `long`에 대입하거나 산술 연산에 쓰면 Java는 객체 안의 값을 꺼내 기본형으로 바꾼다. 이를 언박싱이라고 한다. 언박싱 뒤에는 숫자 비교가 가능하다. 다만 값이 `null`이면 꺼낼 숫자가 없으므로 예외가 난다. 권한 확인처럼 실패를 명확히 처리해야 하는 곳에서는, 암묵적인 변환에 기대기보다 `Objects.equals`로 의도를 드러내는 편이 낫다.

## 4. 실제 코드

아래는 예약 취소 권한을 확인하는 작은 Spring 서비스 예시다. `currentMemberId`는 인증 필터나 Security 설정에서 얻었다고 가정한다. 요청 JSON에서 받은 회원 ID를 그대로 믿는 예제가 아니다.

```java
@Service
@RequiredArgsConstructor
public class ReservationService {
    private final ReservationRepository reservationRepository;

    public void cancel(Long reservationId, Long currentMemberId) {
        Reservation reservation = reservationRepository.findById(reservationId)
                .orElseThrow(() -> new IllegalArgumentException("예약이 없습니다."));

        if (!Objects.equals(reservation.getMemberId(), currentMemberId)) {
            throw new IllegalStateException("예약을 취소할 권한이 없습니다.");
        }

        reservation.cancel();
    }
}
```

`findById` 다음에 바로 권한을 확인한다. 예약이 존재하지 않으면 먼저 끝내므로 없는 예약의 회원 ID를 읽지 않는다. 그 다음 줄의 `Objects.equals`는 왼쪽과 오른쪽의 숫자 값이 같은지 확인한다. 두 값이 모두 `null`인 상태도 `true`가 될 수 있으므로, 예약을 저장할 때 회원 ID가 반드시 있어야 한다는 규칙은 별도로 지켜야 한다.

마지막 `reservation.cancel()`은 예약 상태를 바꾸는 도메인 메서드다. 권한 확인보다 먼저 호출하면 안 된다. 서비스 메서드 안에서 조회, 권한 확인, 상태 변경의 순서를 붙여 두면 코드를 읽는 사람이 취소 조건을 놓치기 어렵다.

## 5. 실제 서비스 적용

작은 Spring 서비스에서는 Controller가 예약 번호만 받고, 현재 회원 ID는 인증 정보에서 꺼내 Service에 넘기는 흐름으로 시작할 수 있다. Controller가 `memberId`를 요청 몸체에서 받으면 사용자가 다른 숫자를 넣을 수 있다. 로그인한 사용자가 누구인지와 요청에 적힌 회원 번호는 역할이 다르다.

입력이 늘어도 ID 비교 자체를 복잡하게 만들 필요는 없다. 대신 예약 조회와 취소가 한 요청 안에서 일관되게 처리되는지 확인해야 한다. 예를 들어 취소 요청 로그에는 예약 번호, 로그인한 회원 식별값, 최종 결과를 남기되 개인정보를 그대로 남기지 않는 기준을 정한다. 처음 확인할 자동화 검사는 “다른 회원으로 로그인한 요청이 취소 예외를 받는가”이다.

엔티티의 회원 ID가 비어 있을 수 있는 구조라면 비교식을 고치기 전에 저장 규칙부터 확인한다. 예약은 회원 없이 존재할 수 없는 모델이라면 데이터 생성 단계에서 `memberId`를 필수로 만들고, 테스트 데이터도 그 규칙을 따라야 한다. `Objects.equals`는 잘못된 데이터를 고쳐 주는 도구가 아니라, 비교가 안전하게 실패하도록 만드는 도구다.

## 6. 흔히 발생하는 문제

### 1) Long 두 개를 ==로 비교한다

현상은 같은 회원의 예약인데도 취소가 거절되는 것이다. 원인은 두 `Long` 객체의 참조를 비교했기 때문이다. 첫 확인 지점은 `reservation.getMemberId() == currentMemberId` 같은 코드다. 해결 방향은 `Objects.equals(reservation.getMemberId(), currentMemberId)`로 바꾸는 것이다. 부작용은 거의 없지만, 둘 다 `null`이면 참이 된다는 점은 저장 규칙으로 막아야 한다.

### 2) longValue()로 억지로 값을 꺼낸다

`reservation.getMemberId().longValue() == currentMemberId`처럼 쓰면 숫자 비교가 되지만, 왼쪽 값이 `null`이면 `NullPointerException`이 난다. 먼저 볼 곳은 회원 ID가 없는 예약 데이터나 테스트 fixture다. 값이 없어도 비교해야 하는 경계라면 `Objects.equals`를 쓰고, 값이 절대 없어서는 안 된다면 생성·저장 시점에 검증한다.

### 3) 요청에서 받은 memberId로 권한을 판단한다

현상은 요청을 조작해 다른 회원 번호를 넣을 여지가 생기는 것이다. 원인은 권한의 근거를 클라이언트 입력에 맡긴 데 있다. 첫 확인 지점은 취소 요청 DTO에 `memberId`가 있는지와 그 값을 Service에 전달하는지다. 해결 방향은 인증이 완료된 서버 쪽 사용자 ID를 사용하고, 요청에는 예약 번호처럼 사용자가 선택한 대상만 받는 것이다.

## 7. 기술 선택의 Trade-off

`Objects.equals`의 장점은 의도가 분명하고 `null`에서도 바로 예외가 나지 않는다는 점이다. JPA 엔티티의 `Long` ID, 요청 DTO, 인증 객체처럼 객체가 오가는 경계에서 특히 읽기 좋다. 단점은 `null`을 허용해도 된다는 뜻으로 오해할 수 있다는 점이다. 예약의 회원 ID가 필수라면 데이터 모델과 생성 코드에서 그 규칙을 따로 강제해야 한다.

값이 반드시 존재하고 기본형으로 이미 다루는 계산이라면 `long`과 `==`가 더 단순하다. 예를 들어 검증이 끝난 뒤의 순번 계산에는 기본형 비교가 자연스럽다. 반대로 데이터베이스 조회 결과, 선택 입력, 인증 값처럼 비어 있을 가능성을 먼저 판단해야 하는 곳에서는 무조건 `long`으로 바꾸지 않는 편이 좋다.

권한 비교를 정할 때는 다음 순서로 판단한다.

1. 이 값이 숫자 자체인가, `Long` 객체인가를 먼저 확인한다.
2. 값이 없을 수 있는지와 없으면 어떤 오류로 처리할지를 정한다.
3. 객체 ID 두 개를 비교한다면 `Objects.equals`를 기본으로 둔다.
4. 회원 ID는 요청 입력이 아니라 서버가 확인한 인증 정보에서 가져온다.

### 참고한 공식 문서

- [Java SE 21 Long API](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/Long.html) — `Long`이 기본형 `long` 값을 감싼 객체이며, 같은 값을 가진 인스턴스를 값으로 다뤄야 한다는 설명을 확인했다.
- [Java SE 21 Objects.equals API](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/Objects.html#equals(java.lang.Object,java.lang.Object)) — 두 객체를 `null`에 안전하게 비교하는 `Objects.equals` 메서드의 동작을 확인했다.
