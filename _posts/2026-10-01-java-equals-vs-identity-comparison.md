---
title: "결재 권한 검사에서 ==와 equals를 구분해야 하는 이유"
date: 2026-10-01 08:55:00 +0900
tags: [Java, Spring, Security, Backend]
excerpt: "결재 문서 권한 검사를 예로 ==와 equals의 차이, 테스트에서만 통과하는 String 리터럴과 Long 캐시 함정, null과 원시 타입 비교, record로 비교 규칙을 모으는 법을 정리한다."
redirect_from:
  - /posts/java-string-equals-post-author/
  - /posts/java-long-equals-reservation-cancel/
---

결재 시스템에는 권한 검사가 곳곳에 있다. 기안 문서는 기안자만 수정할 수 있고, 승인 버튼은 지금 결재 차례인 결재자에게만 열린다. 이런 검사는 대부분 "문서에 저장된 사람"과 "지금 로그인한 사람"이 같은지를 묻는 한 줄로 끝난다. 그런데 이 한 줄에 `==`를 쓰면 테스트는 통과하고 운영에서만 권한 오류가 나는, 찾기 어려운 버그가 생긴다. 비교 대상이 문자열 사번이면 문자열 상수 풀이, 숫자 ID를 `Long`으로 다루면 박싱 캐시가 테스트를 속인다. 이 글은 결재 권한 검사 한 곳을 따라가며 `==`와 `equals`가 각각 무엇을 비교하는지, 테스트에서만 통과하는 두 함정을 어떻게 재현하는지, `null`과 원시 타입을 어떻게 다룰지, 비교 규칙을 값 객체 하나로 모으는 방법까지 정리한다.

> 이 글의 예제는 개념을 설명하기 위해 구성한 코드이며, 특정 서비스의 운영 수치가 아니다.

## 권한 검사 한 줄이 지나가는 길

기안 문서 수정 요청 `PATCH /approval-documents/{documentId}`를 생각해 보자.

1. 인증 필터가 토큰이나 세션에서 로그인 사용자의 사원 ID(`Long`)와 사번(`String`)을 꺼낸다.
2. 서비스가 문서 번호로 결재 문서 엔티티를 조회한다. 엔티티에는 기안자의 사원 ID와 사번이 저장되어 있다.
3. 둘을 비교해 같으면 수정하고, 다르면 403으로 거절한다.

3번에서 비교하는 두 값은 출처가 다르다. 하나는 JDBC 드라이버와 JPA가 DB 행을 읽어 만든 객체이고, 다른 하나는 토큰이나 세션을 파싱해 만든 객체다. 로그에 찍으면 똑같이 `20240017`이나 `E2024017`로 보이지만 메모리에서는 서로 다른 객체다. 문제의 코드는 이렇게 생겼다.

```java
public void update(Long documentId, LoginUser loginUser, UpdateDocumentRequest request) {
    ApprovalDocument document = documentRepository.findById(documentId)
            .orElseThrow(() -> new DocumentNotFoundException(documentId));

    if (document.getDrafterId() != loginUser.employeeId()) {   // Long 두 개를 참조로 비교한다
        throw new AccessDeniedException("기안자만 수정할 수 있습니다.");
    }
    document.update(request.title(), request.content());
}
```

여기서 비교 기준인 로그인 사용자 정보는 반드시 서버가 인증 과정에서 확인한 값이어야 한다. 수정 요청 본문에 `drafterId`를 받아 비교하면 클라이언트가 그 값을 마음대로 바꿔 보낼 수 있다. 요청에는 수정할 제목과 본문처럼 바꿀 값만 받는다.

## ==는 같은 객체인지, equals는 같은 값인지 묻는다

`int`, `long`, `boolean` 같은 원시 타입에서 `==`는 값을 비교한다. 참조 타입에서 `==`는 두 변수가 같은 객체를 가리키는지, 즉 참조 동일성을 비교한다. 내용이 같아도 서로 다른 객체면 `false`다.

`equals`는 값이 같은지, 즉 동등성을 묻는 메서드다. 다만 무엇을 같다고 볼지는 클래스가 정한다. `Object`의 기본 구현은 가장 엄격한 기준인 `x == y`를 그대로 쓴다. `String`은 글자 내용을, `Long`은 담긴 `long` 값을 비교하도록 재정의되어 있다. `Long.equals`는 인자가 `null`이 아니고 같은 값을 담은 `Long`일 때만 `true`다. 값 비교의 의미가 클래스마다 다르다는 점도 기억해 둔다. 예를 들어 `BigDecimal.equals`는 스케일까지 비교해서 `1.0`과 `1.00`을 다르게 본다. 정산 금액처럼 수치만 같은지 볼 때는 `compareTo`를 쓴다.

정리하면 사번, 사원 ID, 문서 번호처럼 "같은 값이면 같은 것"인 데이터는 `equals` 계열로 비교한다. `==`로 비교해도 되는 참조형은 enum 상수처럼 값마다 인스턴스가 하나뿐이라고 보장되는 경우 정도다. enum은 오히려 `==`가 더 낫다. `document.getStatus() == ApprovalStatus.PENDING`은 상태가 `null`이어도 예외 없이 `false`가 되고, 서로 다른 enum 타입을 비교하면 컴파일 오류로 잡힌다. 같은 비교를 `equals`로 쓰면 왼쪽이 `null`일 때 NPE가 나고, 엉뚱한 타입을 넘겨도 컴파일러가 막지 않는다.

## 문자열: 리터럴로 짠 테스트만 통과한다

Java 언어 명세(JLS 3.10.5)는 문자열 리터럴이 항상 같은 `String` 인스턴스를 가리킨다고 정한다. 리터럴과 상수식의 결과는 `String.intern`을 거친 것처럼 공유되기 때문이다. 반면 실행 중에 연결해서 만든 문자열은 새로 생성된 별개의 객체다.

그래서 테스트 픽스처에서 기안자 사번과 로그인 사번을 둘 다 `"E2024017"` 리터럴로 넣으면 두 변수는 같은 객체를 가리키고 `==`도 통과한다. 운영에서는 기안자 사번은 DB 조회 결과로, 로그인 사번은 토큰 파싱 결과로 만들어지므로 같은 객체일 이유가 없다. 차이는 테스트로 바로 재현된다.

```java
class StringIdentityTest {

    @Test
    void 리터럴끼리는_같은_인스턴스라_==가_통과한다() {
        String drafterNo = "E2024017";
        String loginNo = "E2024017";

        assertThat(drafterNo == loginNo).isTrue();            // 상수 풀의 같은 객체
    }

    @Test
    void 실행_중에_연결한_문자열은_==로_비교하면_실패한다() {
        String drafterNo = "E2024017";
        String prefix = "E";
        String loginNo = prefix + "2024017";                  // 실행 중 연결: 새 객체

        assertThat(drafterNo == loginNo).isFalse();
        assertThat(drafterNo.equals(loginNo)).isTrue();
    }

    @Test
    void 바이트에서_복원한_문자열도_새_객체다() {
        String drafterNo = "E2024017";
        byte[] claim = "E2024017".getBytes(StandardCharsets.UTF_8);   // 토큰 클레임을 읽었다고 가정
        String loginNo = new String(claim, StandardCharsets.UTF_8);

        assertThat(drafterNo == loginNo).isFalse();
        assertThat(drafterNo.equals(loginNo)).isTrue();
    }
}
```

두 번째 테스트에는 함정이 하나 더 있다. `prefix`를 `final String prefix = "E";`로 바꾸면 `prefix + "2024017"`이 상수식이 되어 컴파일 시점에 계산되고, 리터럴처럼 공유되어 `==`가 `true`로 바뀐다. 변수 선언에 `final` 하나를 붙였을 뿐인데 비교 결과가 달라진다. 참조 비교가 얼마나 우연에 기대는지 보여 주는 예다.

`intern()`을 양쪽에 붙여 `==`로 비교하는 방법도 이론상 동작하지만 권하지 않는다. 모든 경로가 빠짐없이 `intern()`을 거쳐야 하고, 읽는 사람이 의도를 알기 어렵다. 값을 비교하려면 `equals`를 쓴다.

`equals`로 바꾼 뒤에도 문자열 식별자에는 확인할 것이 남는다. `String.equals`는 대소문자와 공백까지 그대로 비교한다. 사번을 사내 인증 시스템에서 받아 오는데 그쪽은 소문자로, 인사 DB는 대문자로 관리한다면 같은 사람이어도 비교가 실패한다. 이때 비교하는 곳마다 `equalsIgnoreCase`나 `trim()`을 붙이면 한 곳만 빠뜨려도 다시 틀린다. 값이 시스템에 들어오는 경계에서 한 번 정규화하고(예: `strip()` 후 `toUpperCase(Locale.ROOT)`), 그 뒤로는 정규화된 값끼리 `equals`로 비교한다. 이 규칙도 뒤에서 다룰 값 객체 생성자에 두면 한곳에서 관리된다.

## Long: 작은 ID에서만 통과한다

숫자 ID는 더 교묘하다. `Long.valueOf(long)` 문서는 -128부터 127까지의 값을 항상 캐시하고, 그 밖의 값도 캐시할 수 있다고 적고 있다. JLS 5.1.7도 이 범위의 정수 상수를 박싱한 결과는 항상 `==`로 같다고 보장한다. 자동 박싱은 이 캐시를 거치므로 같은 작은 값을 따로 박싱해도 같은 객체가 나온다.

테스트 데이터의 사원 ID를 `1L`, `2L`처럼 작게 잡으면 `!=` 비교는 언제나 의도대로 동작하고 테스트도 통과한다. 개발 DB의 시드 계정도 ID가 작다면 화면 테스트까지 통과한다. 운영의 사원 ID는 대부분 128보다 크므로, 정작 실제 기안자는 자기 문서를 수정하지 못한다.

```java
class LongIdentityTest {

    // 버그를 재현하려고 남긴 비교. 운영 코드에서 쓰지 않는다.
    private static boolean sameByIdentity(Long drafterId, Long loginId) {
        return drafterId == loginId;
    }

    @ParameterizedTest
    @ValueSource(longs = {1L, 42L, 127L})
    void 캐시_범위의_ID는_따로_만든_Long이어도_==가_통과한다(long id) {
        Long fromEntity = Long.valueOf(id);                   // DB 값을 박싱했다고 가정
        Long fromToken = Long.valueOf(String.valueOf(id));    // 토큰 클레임 문자열을 파싱했다고 가정

        assertThat(sameByIdentity(fromEntity, fromToken)).isTrue();
    }

    @ParameterizedTest
    @ValueSource(longs = {128L, 20_240_017L})
    void 캐시_범위_밖의_ID는_값이_같아도_==가_실패한다(long id) {
        Long fromEntity = Long.valueOf(id);
        Long fromToken = Long.valueOf(String.valueOf(id));

        assertThat(fromEntity).isEqualTo(fromToken);          // equals로는 같다
        assertThat(sameByIdentity(fromEntity, fromToken)).isFalse();
    }
}
```

두 번째 테스트는 OpenJDK에서 통과한다. 다만 명세는 범위 밖의 값도 캐시할 수 있다고만 하므로, 이 테스트가 보여 주는 것은 "항상 다르다"가 아니라 "같다고 기대할 근거가 없다"이다. 결과가 구현과 값의 크기에 따라 달라지는 비교를 권한 검사에 둘 수는 없다.

이 버그가 늘 "정당한 사용자를 막는" 쪽으로만 나타나는 것도 아니다. 결재에는 "기안자는 자기 문서를 승인할 수 없다"처럼 같으면 막는 규칙도 있다. `if (document.getDrafterId() == approver.employeeId())`로 자기 결재를 막았다면, 캐시 범위 밖의 ID에서는 같은 사람인데도 조건이 `false`가 되어 기안자가 자기 문서를 승인할 수 있다. 같으면 허용하는 검사에서는 실패가 거절로, 같으면 막는 검사에서는 실패가 통과로 나타난다. 그래서 참조 비교는 기능 버그이면서 보안 버그다.

같은 계열의 실수가 하나 더 있다. `Objects.equals(document.getDrafterId(), 20240017)`처럼 `long` 접미사 없이 정수 리터럴을 넘기면 오른쪽은 `Integer`로 박싱된다. `Long.equals`는 인자가 `Long`일 때만 `true`이므로 이 비교는 값과 상관없이 항상 `false`다. `equals` 계열은 타입까지 맞아야 한다. 컬렉션도 같은 규칙을 따른다. 결재 단계별 결재자를 `Map<Long, EmployeeSummary>`에 담아 두고 `int` 단계 번호로 `get(stepNo)`를 부르면 키가 `Integer`로 박싱되어 항상 `null`이 나온다. `Map.get`이 `Object`를 받기 때문에 컴파일 단계에서 걸러지지 않는다는 점이 더 위험하다.

## null을 어떻게 다룰 것인가

`==`를 버리고 나면 `null`이 다음 문제다. 데이터 이관 과정에서 기안자 ID가 비어 있는 문서가 있을 수 있고, 배치나 시스템 계정처럼 사원 ID가 없는 주체가 호출할 수도 있다.

`document.getDrafterId().equals(loginId)`는 왼쪽이 `null`이면 `NullPointerException`이 난다. `Objects.equals(a, b)`는 이 예외를 피한다. 문서에 따르면 둘 다 `null`이면 `true`, 첫 번째만 `null`이면 `false`, 그 밖에는 첫 번째 인자의 `equals`를 호출한다. 여기에 권한 검사의 함정이 있다. 기안자 ID가 비어 있는 문서를 사원 ID가 없는 주체가 수정하려 하면 `Objects.equals(null, null)`이 `true`가 되어 검사를 통과한다. null 안전한 비교가 곧 안전한 권한 검사는 아니다.

원시 타입으로 비교하는 방법도 있다. `LoginUser`가 `long employeeId`를 가진다면 `document.getDrafterId() == loginUser.employeeId()`는 `Long`을 언박싱해 숫자로 비교하므로 캐시 문제가 없다. 대신 JLS 5.1.8에 따라 언박싱할 값이 `null`이면 `NullPointerException`이 난다. Java 15부터 기본으로 켜진 상세 NPE 메시지 덕분에 원인은 금방 보인다.

```text
java.lang.NullPointerException: Cannot invoke "java.lang.Long.longValue()" because the return value of "com.example.approval.ApprovalDocument.getDrafterId()" is null
	at com.example.approval.ApprovalDocumentService.update(ApprovalDocumentService.java)
```

빨리 실패한다는 점은 장점이지만, 사용자는 403 대신 500을 받고 로그에는 권한 문제가 아니라 NPE로 남는다. 권한 검사에서는 `null`을 명시적으로 거절하는 쪽이 의도를 가장 잘 드러낸다.

```java
public static void requireDrafter(ApprovalDocument document, LoginUser loginUser) {
    Long drafterId = document.getDrafterId();
    Long loginId = loginUser.employeeId();
    if (drafterId == null || loginId == null) {
        throw new AccessDeniedException("권한을 확인할 수 없습니다: documentId=" + document.getId());
    }
    if (!drafterId.equals(loginId)) {
        throw new AccessDeniedException("기안자만 수정할 수 있습니다: documentId=" + document.getId());
    }
}
```

비교 방법을 나란히 놓으면 다음과 같다.

| 비교 방법 | 동작 | 쓰지 말아야 할 때 |
|---|---|---|
| `a == b` (참조형) | 같은 객체인지 본다 | 값 비교 전부. enum처럼 인스턴스가 하나뿐인 경우만 예외다 |
| `a.equals(b)` | 값을 비교하고, `a`가 `null`이면 NPE | `a`가 비어 있을 수 있는데 그 경우를 따로 처리하지 않았을 때 |
| `Objects.equals(a, b)` | `null`에 안전하고, 둘 다 `null`이면 `true` | 권한 검사처럼 "둘 다 비어 있음"을 통과시키면 안 될 때. 이때는 `null` 검사를 먼저 둔다 |
| `long` 원시 타입과 `==` | 숫자로 비교하고, 언박싱할 값이 `null`이면 NPE | DB 조회 결과나 선택 입력처럼 비어 있는 경우를 별도 오류로 응답해야 할 때 |
| 값 객체(record)와 전용 메서드 | 타입이 보장된 값 비교 | 비교가 한두 곳뿐이라 타입을 새로 만드는 비용이 더 클 때 |

## 비교 규칙을 값 객체로 모으기

사원 ID, 문서 번호, 부서 ID가 모두 `Long`이면 문서 번호와 사원 ID를 비교하는 실수도 컴파일러가 막지 못한다. `equals(Object)`는 아무 타입이나 받고 조용히 `false`를 돌려줄 뿐이다. 자주 비교하는 ID라면 record로 값 객체를 만들어 규칙을 한곳에 모을 수 있다.

```java
public record EmployeeId(long value) {

    public EmployeeId {
        if (value <= 0) {
            throw new IllegalArgumentException("사원 ID는 양수여야 한다: " + value);
        }
    }

    public static EmployeeId from(Long value) {
        if (value == null) {
            throw new IllegalArgumentException("사원 ID가 비어 있다");
        }
        return new EmployeeId(value);
    }

    public boolean isSameEmployee(EmployeeId other) {   // 다른 ID 타입을 넘기면 컴파일되지 않는다
        return equals(other);
    }
}
```

`Record` 문서에 따르면 record가 자동으로 만드는 `equals`는 같은 record 타입이고 모든 구성 요소가 같을 때 `true`다. 참조형 구성 요소는 `Objects.equals`로, 원시형은 래퍼 클래스의 `compare`로 비교한다. `hashCode`도 구성 요소에서 만들어지므로 두 메서드가 어긋나지 않는다. `null`은 `from`에서 한 번만 거르고, 그 뒤로는 비교할 때마다 신경 쓰지 않아도 된다. 엔티티는 컬럼을 `Long`으로 두고 `EmployeeId drafter()` 같은 조회 메서드에서 변환해 돌려주면 된다. 엔티티 객체끼리 `equals`로 비교하는 문제는 영속성 컨텍스트와 프록시까지 얽힌 별도 주제이므로, 권한 검사에서는 엔티티가 아니라 ID 값을 비교하는 편이 단순하다.

record 대신 클래스를 직접 쓴다면 `Object` 문서의 계약을 지켜야 한다. `equals`는 반사성, 대칭성, 추이성, 일관성을 만족해야 하고 `null`과 비교하면 `false`여야 한다. 그리고 `equals`가 같은 두 객체는 `hashCode`도 같아야 하므로, `equals`를 재정의하면 `hashCode`도 함께 재정의해야 한다. 이것을 빠뜨리면 결재선을 `Set`에 담아 "이 사람이 결재선에 있는가"를 물을 때 틀린 답이 나온다.

```java
class EmployeeIdContractTest {

    // equals만 재정의하고 hashCode를 빠뜨린 클래스
    static final class BrokenEmployeeId {
        private final long value;

        BrokenEmployeeId(long value) {
            this.value = value;
        }

        @Override
        public boolean equals(Object o) {
            return o instanceof BrokenEmployeeId other && other.value == value;
        }
    }

    @Test
    void hashCode를_빠뜨리면_결재선_Set에서_찾지_못한다() {
        Set<BrokenEmployeeId> approvalLine = new HashSet<>(List.of(new BrokenEmployeeId(20_240_017L)));

        assertThat(new BrokenEmployeeId(20_240_017L)).isEqualTo(new BrokenEmployeeId(20_240_017L));
        // 객체마다 다른 기본 hashCode 때문에 equals까지 가지 못한다
        assertThat(approvalLine.contains(new BrokenEmployeeId(20_240_017L))).isFalse();
    }

    @Test
    void record는_equals와_hashCode를_함께_만든다() {
        Set<EmployeeId> approvalLine = Set.of(new EmployeeId(20_240_017L), new EmployeeId(20_240_021L));

        assertThat(approvalLine).contains(new EmployeeId(20_240_017L));
        assertThat(new EmployeeId(20_240_017L)).hasSameHashCodeAs(new EmployeeId(20_240_017L));
    }
}
```

`HashSet`은 먼저 `hashCode`로 후보를 좁히고 그 안에서만 `equals`를 호출한다. 기본 `hashCode`는 객체마다 다르게 나오는 것이 보통이므로, 값이 같아도 `contains`가 `false`를 돌려준다. 결재 차례 검사가 이런 `Set`에 기대고 있다면 정당한 결재자가 승인 버튼을 누를 수 없게 된다.

## 어떻게 확인하나

먼저 위의 재현 테스트를 그대로 돌려 본다.

```bash
./gradlew test --tests "*IdentityTest" --tests "*EmployeeIdContractTest"
```

다음으로 테스트 데이터를 점검한다. 픽스처의 ID를 `1L`, `2L`로 두는 습관이 `Long` 캐시 버그를 숨긴다. 테스트 데이터 빌더의 기본 사원 ID를 `20_240_017L`처럼 128 이상의 현실적인 값으로 바꾸고, 문자열 식별자는 리터럴 대신 `new String(...)`이나 JSON 파싱 결과로 만들면 참조 비교가 남아 있을 때 테스트가 먼저 실패한다.

코드에서 의심스러운 비교를 찾을 때는 ID나 번호를 돌려주는 메서드 호출 바로 뒤에 `==`나 `!=`가 오는 줄을 검색한다.

```bash
grep -rnE "(Id|No)\(\)\s*[!=]=\s*" src/main/java
```

검색은 출발점일 뿐이다. 정적 분석 도구를 쓰고 있다면 SpotBugs의 `RC_REF_COMPARISON`(박싱 타입 같은 참조를 `==`로 비교)과 `ES_COMPARING_STRINGS_WITH_EQ`(문자열을 `==`로 비교) 경고를 빌드에서 확인한다. IDE도 같은 종류의 경고를 보여 주므로 무시하지 않는다.

운영에서는 거절 로그를 보고 판단한다. 권한 거절 로그에 비교한 두 값을 함께 남겨 두면 원인을 바로 가를 수 있다.

```text
WARN  [http-nio-8080-exec-5] c.e.a.ApprovalDocumentService - 수정 거절: documentId=88123, drafterId=20240017, loginEmployeeId=20240017
```

같은 값이 찍혔는데 거절됐다면 가장 먼저 비교 연산자와 비교 대상의 타입을 본다. 값이 다르게 찍혔다면 비교식이 아니라 인증 정보에서 사번과 사원 ID를 혼동했는지, 문서에 기안자가 처음부터 잘못 저장됐는지를 확인한다. 로그에는 ID만 남기고 토큰이나 개인정보는 남기지 않는다. 거절 응답은 보통 403이지만, 다른 부서 문서의 존재 자체를 감춰야 한다면 404로 응답하는 정책도 있다. 어느 쪽이든 공통 예외 처리기 한곳에서 정해, 서비스마다 다르게 응답하지 않게 한다.

## 정리

- 사번, 사원 ID, 문서 번호처럼 값이 같으면 같은 데이터는 `==`가 아니라 `equals` 계열로 비교한다.
- 테스트가 통과해도 안심하지 않는다. 문자열 리터럴은 같은 객체를 공유하고, `Long`은 -128부터 127까지 캐시되어 참조 비교를 숨긴다.
- 테스트 픽스처의 ID는 128 이상으로, 문자열은 실행 중에 만든 값으로 둔다.
- 같으면 허용하는 검사뿐 아니라 자기 결재 금지처럼 같으면 막는 검사도 같은 기준으로 점검한다.
- `Objects.equals`는 `null` 안전하지만 둘 다 `null`이면 `true`다. 권한 검사에서는 `null`을 먼저 명시적으로 거절한다.
- `long` 원시 타입 비교는 캐시 문제가 없지만 `null`에서 NPE가 나므로, 값이 반드시 있는 구간에서만 쓴다.
- 자주 비교하는 ID는 record 값 객체로 만들어 `equals`와 `hashCode`를 함께 얻고, 타입이 정해진 비교 메서드를 둔다.
- 권한의 기준은 요청 본문이 아니라 서버가 인증으로 확인한 사용자 정보다.

## 참고한 공식 문서

- [JLS 21, 3.10.5 String Literals](https://docs.oracle.com/javase/specs/jls/se21/html/jls-3.html#jls-3.10.5) — 문자열 리터럴과 상수식이 같은 인스턴스를 공유하고, 실행 중 연결한 문자열은 새 객체라는 규칙
- [JLS 21, 5.1.7 Boxing Conversion](https://docs.oracle.com/javase/specs/jls/se21/html/jls-5.html#jls-5.1.7) — -128부터 127까지의 상수를 박싱하면 항상 같은 객체라는 보장, 같은 장의 5.1.8에서 `null` 언박싱이 NPE를 던진다는 규칙
- [Java SE 21 API: Long.valueOf(long)](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/Long.html#valueOf(long)) — -128부터 127까지 항상 캐시하고 범위 밖도 캐시할 수 있다는 설명, `Long.equals`의 조건
- [Java SE 21 API: Object](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/Object.html) — `equals`의 계약과 기본 구현이 참조 동일성이라는 점, `equals`를 재정의하면 `hashCode`도 재정의해야 한다는 계약
- [Java SE 21 API: Record](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/Record.html) — record가 자동으로 제공하는 `equals`와 `hashCode`의 구성 요소별 비교 방식
