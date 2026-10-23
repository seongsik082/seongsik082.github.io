---
title: "부서별 사용 통계 API에서 List·Set·Map과 Collectors 선택이 응답 계약을 바꾸는 이유"
date: 2026-08-31 16:55:00 +0900
tags: [Java, Collection, Stream, API, Backend]
excerpt: "부서별 시스템 사용 통계·정산 집계 API를 예로 List·Set·Map 선택이 중복 제거, 응답 순서, 조회 비용을 어떻게 바꾸는지와 groupingBy·toMap 키 충돌, 불변 반환을 정리한다."
redirect_from:
  - /posts/java-collection-api-contract-cost/
  - /posts/java-stream-filter-map-product-names/
  - /posts/java-map-reservation-attendance/
---

관리자 화면에 "부서별 시스템 사용 현황" 메뉴가 있다고 하자. 한 달 단위로 부서마다 접속 건수, 활성 사용자 수, 그리고 해당 부서에 배분된 시스템 사용료 정산 금액을 보여 주고, 같은 내용을 엑셀로도 내려 준다. 현업이 준 요구사항은 짧다. 부서는 조직도 순서대로 보여 줄 것, 같은 사람이 여러 번 접속해도 활성 사용자는 한 명으로 셀 것, 정산 금액은 부서별 정산 내역의 합으로 보여 줄 것.

이 짧은 문장들이 사실은 컬렉션 계약이다. "조직도 순서대로"는 순서를, "한 명으로"는 중복 제거를, "부서별 합"은 키 기준 집계와 충돌 처리를 요구한다. 처음 구현에서 이 계약을 자료구조에 옮기지 않으면, 테스트 데이터에서는 잘 돌다가 조직 개편이나 데이터 증가 같은 사소한 변화에 응답 순서와 숫자가 함께 흔들린다. 이 글은 이 API 하나를 따라가며 `List`, `Set`, `Map`과 Stream `Collectors`를 고르는 기준을 정리한다.

> 이 글의 예제는 개념을 설명하기 위해 구성한 코드이며, 특정 서비스의 운영 수치가 아니다.

## 처음 구현이 깨지는 방식

빨리 만든 첫 버전은 보통 이런 모양이다. 로그를 부서 코드로 묶고, 묶인 결과를 순회하며 응답 행을 만든다.

```java
// 첫 구현: 동작은 하지만 계약이 코드에 드러나지 않는다
Map<String, List<UsageLog>> logsByDept = logs.stream()
        .collect(Collectors.groupingBy(UsageLog::deptCode));

List<DeptUsageRow> rows = new ArrayList<>();
for (Map.Entry<String, List<UsageLog>> entry : logsByDept.entrySet()) { // (1) 순회 순서 보장 없음
    List<String> users = new ArrayList<>();
    for (UsageLog log : entry.getValue()) {
        if (!users.contains(log.userId())) {                           // (2) 매번 처음부터 비교
            users.add(log.userId());
        }
    }
    Department dept = deptByCode.get(entry.getKey());                  // (3) 없으면 null
    rows.add(new DeptUsageRow(entry.getKey(), dept.deptName(),
            entry.getValue().size(), users.size(), BigDecimal.ZERO));
}
return rows;
```

이 코드에는 문제가 네 가지 숨어 있다.

1. `groupingBy`가 만든 `Map`의 구현체와 순회 순서는 문서상 보장되지 않는다. 개발 DB의 부서 몇 개로는 우연히 원하는 순서가 나올 수 있지만, 부서 코드가 바뀌거나 늘면 화면과 엑셀의 순서가 달라진다.
2. 활성 사용자 중복 제거를 `List.contains`로 한다. 확인할 때마다 목록을 앞에서부터 훑으므로 로그가 늘수록 비용이 제곱에 가깝게 커진다.
3. 조직 개편으로 폐지된 부서 코드가 과거 로그에 남아 있으면 `deptByCode.get()`이 `null`을 돌려주고 `NullPointerException`이 난다.
4. 응답의 뼈대가 "로그가 있는 부서"다. 그달에 접속이 한 번도 없던 부서는 0건으로 나오는 대신 아예 사라진다.

네 가지 모두 문법 문제가 아니다. 응답 순서는 무엇이 책임지는지, 중복은 어떤 기준으로 없애는지, 없는 키는 어떻게 다루는지가 정해지지 않은 결과다.

## 요구사항을 컬렉션 계약으로 옮긴다

요구사항 문장마다 필요한 성질을 적고 그에 맞는 자료구조를 고르면 대부분의 선택이 자연스럽게 정해진다.

| 요구사항 | 필요한 성질 | 선택 |
| --- | --- | --- |
| 부서는 조직도 순서대로 보여 준다 | 외부 기준(`sort_order`)에 따른 순서 | 정렬된 `List<Department>`를 응답의 뼈대로 쓴다 |
| 같은 사람이 여러 번 접속해도 한 명 | `equals` 기준 중복 제거 | `Set<String>` |
| 부서 코드로 접속 건수, 정산 금액을 찾는다 | 키 기반 조회 | `Map<String, …>` (내부 인덱스, 순서는 계약이 아님) |
| 월별 추이는 월 오름차순 | 키 자체의 정렬 순서 | `TreeMap<YearMonth, Long>` |
| 응답은 만든 뒤 바뀌지 않는다 | 수정 불가 | `Stream.toList()`, `List.copyOf` |

핵심은 응답 순서를 책임지는 자료구조를 하나로 정하는 것이다. 이 API에서는 조직도 순서로 정렬한 부서 목록이 그 역할을 맡고, 나머지 `Map`은 그 목록을 따라가며 값을 꺼내는 조회용 인덱스로만 쓴다. 이렇게 나누면 `Map`의 구현체를 무엇으로 고르든 응답 순서는 흔들리지 않는다.

## List, Set, Map이 각각 약속하는 것과 비용

`List`는 순서가 있고 중복을 허용한다. 입력과 응답처럼 순서 자체가 의미인 곳에 맞는다. 대신 `contains`는 앞에서부터 차례로 비교하므로, "이미 본 값인가"를 반복해서 묻는 용도로는 맞지 않는다.

`Set`은 `equals` 기준으로 같은 원소를 한 번만 담는다. 순서는 구현체마다 다르다. `HashSet`은 순회 순서를 약속하지 않고, `LinkedHashSet`은 처음 넣은 순서를, `TreeSet`은 정렬 순서를 유지한다. 해시 기반 구현은 해시가 고르게 퍼진다는 전제에서 추가와 조회가 원소 수와 거의 무관한 시간에 끝난다. 활성 사용자 수처럼 "몇 명인가"만 필요하면 `HashSet`으로 충분하고, 첫 접속 순서까지 보여 줘야 할 때만 `LinkedHashSet`을 고른다.

반대로 중복이 곧 데이터인 곳에서는 `Set`을 쓰면 안 된다. 접속 건수는 같은 사람이 열 번 들어왔다면 열 건이어야 한다. 활성 사용자를 세려고 만든 `Set`을 접속 건수 계산에 재사용하거나, 중복은 어차피 없애는 편이 낫다며 로그 목록을 미리 `Set`으로 바꾸면 코드는 빨라 보여도 숫자가 틀린다. 중복 제거는 성능 최적화가 아니라 요구사항이 정하는 계산 규칙이다.

`Map`은 키에서 값으로 가는 인덱스다. Java `Map` 문서는 `TreeMap`처럼 순서를 보장하는 구현과 `HashMap`처럼 보장하지 않는 구현이 있다고 명시한다. `LinkedHashMap`은 삽입 순서를 유지하고, 이미 있는 키를 다시 `put`해도 순서가 바뀌지 않는다. 연결 목록을 유지하는 비용이 있어 `HashMap`보다 약간 느릴 수 있다. `TreeMap`은 키의 자연 순서나 지정한 `Comparator`로 정렬하며, 조회와 추가에 log(n) 시간이 든다.

`TreeMap`에서 한 가지 조심할 점은 정렬 기준이 `equals`와 일관되어야 한다는 것이다. 예를 들어 대소문자를 무시하는 `Comparator`를 쓰면 `d100`과 `D100`이 같은 키로 취급된다. 의도한 것이 아니라면 서로 다른 두 부서의 데이터가 한 키 아래로 조용히 섞인다. 또 키로 쓰는 객체는 바뀌지 않아야 한다. 맵에 들어간 뒤 `equals` 결과가 달라지도록 키를 수정하면 `Map`의 동작은 정의되지 않는다. 부서 코드처럼 `String`이나 불변 `record`를 키로 쓰는 이유다.

## Stream으로 집계하기: filter, map, collect

Stream은 원본 컬렉션을 바꾸지 않고, 고르는 단계(`filter`)와 바꾸는 단계(`map`)를 이어 붙인 다음 마지막 단계(`collect`, `toList`)에서 결과를 만든다. 중간 단계는 지연 실행되어 마지막 연산을 호출해야 실제로 계산이 시작되며, 한 번 사용한 Stream은 다시 쓸 수 없다. 이 성질 덕분에 "배치 계정 로그는 빼고, 부서 코드로 묶고, 사용자 수를 센다" 같은 집계를 위에서 아래로 읽히게 쓸 수 있다.

앞의 계약을 반영한 집계 코드는 다음과 같다. 순수 Java 클래스로 두어 Spring 없이도 테스트할 수 있게 했다.

```java
public record Department(String deptCode, String deptName, int sortOrder) {}
public record UsageLog(String deptCode, String userId, boolean batchAccount, LocalDateTime accessedAt) {}
public record SettlementLine(String deptCode, String costItem, BigDecimal amount) {}
public record DeptUsageRow(String deptCode, String deptName,
                           long accessCount, int activeUsers, BigDecimal settlementAmount) {}

@Component
public class DeptUsageAggregator {

    public DeptUsageReport summarize(List<Department> departments,
                                     List<UsageLog> logs,
                                     List<SettlementLine> settlements) {
        // 1) 응답 순서는 이 목록 하나만 책임진다
        List<Department> ordered = departments.stream()
                .sorted(Comparator.comparingInt(Department::sortOrder)
                        .thenComparing(Department::deptCode))
                .toList();

        // 2) 부서 코드가 겹치면 기준 데이터 오류다. 덮어쓰지 않고 실패한다
        Map<String, Department> deptByCode = ordered.stream()
                .collect(Collectors.toMap(
                        Department::deptCode,
                        Function.identity(),
                        (a, b) -> {
                            throw new IllegalStateException(
                                    "부서 코드 중복: " + a.deptCode() + " (" + a.deptName() + ", " + b.deptName() + ")");
                        }));

        // 3) 배치·연계 계정의 접속은 사용 통계에서 뺀다
        List<UsageLog> userLogs = logs.stream()
                .filter(log -> !log.batchAccount())
                .toList();

        Map<String, Long> accessCountByDept = userLogs.stream()
                .collect(Collectors.groupingBy(UsageLog::deptCode, Collectors.counting()));

        // 4) 같은 사람이 여러 번 접속해도 한 명: Set으로 모은 뒤 크기만 쓴다
        Map<String, Integer> activeUsersByDept = userLogs.stream()
                .collect(Collectors.groupingBy(UsageLog::deptCode,
                        Collectors.collectingAndThen(
                                Collectors.mapping(UsageLog::userId, Collectors.toSet()),
                                Set::size)));

        // 5) 같은 부서의 정산 줄 여러 개는 합산이 의도된 의미다
        Map<String, BigDecimal> settlementByDept = settlements.stream()
                .collect(Collectors.toMap(
                        SettlementLine::deptCode,
                        SettlementLine::amount,
                        BigDecimal::add));

        // 6) 정렬된 부서 목록을 따라 응답을 만든다. 접속이 없던 부서도 0으로 남는다
        List<DeptUsageRow> rows = ordered.stream()
                .map(d -> new DeptUsageRow(
                        d.deptCode(),
                        d.deptName(),
                        accessCountByDept.getOrDefault(d.deptCode(), 0L),
                        activeUsersByDept.getOrDefault(d.deptCode(), 0),
                        settlementByDept.getOrDefault(d.deptCode(), BigDecimal.ZERO)))
                .toList();

        // 7) 조직도에 없는 부서 코드는 버리지 않고 따로 드러낸다
        Set<String> unmapped = Stream.concat(
                        accessCountByDept.keySet().stream(),
                        settlementByDept.keySet().stream())
                .filter(code -> !deptByCode.containsKey(code))
                .collect(Collectors.toCollection(TreeSet::new));

        return new DeptUsageReport(rows, unmapped);
    }
}
```

`getOrDefault`의 기본값은 "그 부서에는 데이터가 없었다"는 뜻으로 0을 쓰는 것이 맞는 경우에만 쓴다. 반대로 조직도에 없는 코드는 기본값으로 덮을 대상이 아니라 확인해야 할 데이터라서 `unmapped`로 분리했다. 폐지·통합된 부서의 과거 로그를 어느 부서로 귀속할지는 개발자가 정할 일이 아니라 현업과 정할 정책이다. 코드가 할 일은 그 존재를 숨기지 않는 것이다.

월별 추이처럼 키 자체의 순서가 계약일 때는 `groupingBy`에 map factory를 넘긴다. `YearMonth`는 `Comparable`이므로 `TreeMap`이 월 오름차순을 보장한다.

```java
Map<YearMonth, Long> monthlyAccess = userLogs.stream()
        .collect(Collectors.groupingBy(
                log -> YearMonth.from(log.accessedAt()),
                TreeMap::new,
                Collectors.counting()));
```

다만 접속이 없던 달은 키 자체가 생기지 않는다. 그래프에 빈 달도 0으로 보여야 한다면 기간의 모든 월을 먼저 만들고 `getOrDefault`로 채운다. 부서 목록을 뼈대로 삼은 것과 같은 원리다.

## toMap의 키 충돌: 예외, 합산, 덮어쓰기

`Collectors.toMap(keyMapper, valueMapper)`는 키가 겹치면 `IllegalStateException`을 던진다. 운영에서 이 예외를 처음 만나면 merge function에 `(a, b) -> b`를 넣어 "고치는" 경우가 많다. 하지만 merge function은 예외를 없애는 장치가 아니라 "키가 겹친다는 것이 이 도메인에서 무슨 뜻인가"에 대한 답이다.

- 겹치면 데이터 오류인 경우: 부서 기준 정보에 같은 코드가 두 번 있다면, 조직 이력 테이블을 조회하면서 유효 기간 조건을 빠뜨렸을 가능성이 높다. 위 코드처럼 문맥을 담아 예외를 던지고 조회 쿼리를 고친다.
- 겹치는 것이 정상이고 합쳐야 하는 경우: 정산 줄처럼 같은 부서에 여러 비용 항목이 있다면 `BigDecimal::add`로 합산하는 것이 의미에 맞다.
- 겹치는 것이 정상이고 하나를 골라야 하는 경우: 이력 데이터라면 "마지막에 온 값"이 아니라 기준을 코드에 적는다.

```java
// "나중에 온 값"이 아니라 "적용 시작일이 가장 늦은 이력"을 명시한다
Map<String, DeptHistory> latestByCode = histories.stream()
        .collect(Collectors.toMap(
                DeptHistory::deptCode,
                Function.identity(),
                BinaryOperator.maxBy(Comparator.comparing(DeptHistory::validFrom))));
```

`(a, b) -> b`가 위험한 이유는 결과가 Stream의 원소 순서에 달려 있기 때문이다. 그 순서가 `ORDER BY` 없는 SQL 결과에서 왔다면 실행할 때마다 다른 값이 남을 수 있다. 값이 여러 개인 것이 정상이고 모두 보존해야 한다면 `toMap` 대신 `groupingBy(SettlementLine::deptCode, Collectors.mapping(SettlementLine::costItem, Collectors.toList()))`처럼 값을 목록으로 모은다.

`null`도 확인해 둔다. `toUnmodifiableMap`은 `null` 키와 값을 허용하지 않는다고 문서에 명시돼 있고, `toMap` 역시 현재 JDK 구현에서는 값이 `null`이면 `NullPointerException`이 난다. 정산 금액 컬럼이 `NULL`일 수 있는 데이터라면 매핑 전에 정책을 정해야 한다.

## 반환할 때는 순서와 불변을 함께 정한다

집계 결과를 돌려줄 때는 "호출한 쪽이 이 컬렉션을 바꿀 수 있는가"와 "순서가 유지되는가"를 같이 봐야 한다. 둘을 따로 생각하면 하나를 지키다 다른 하나를 잃는다.

- `Stream.toList()`가 돌려주는 `List`는 수정할 수 없고, 수정 메서드를 호출하면 `UnsupportedOperationException`이 난다.
- `Collectors.toList()`는 반환되는 `List`의 타입과 수정 가능 여부를 보장하지 않는다. 결과에 항목을 더해야 한다면 `Collectors.toCollection(ArrayList::new)`로 의도를 드러낸다.
- `Map.of`, `Map.copyOf`가 만드는 불변 `Map`은 순회 순서가 정해져 있지 않고 바뀔 수 있다. 순서를 지키려고 만든 `LinkedHashMap`을 `Map.copyOf`로 감싸면 불변은 얻지만 순서 보장은 잃는다. `Set.copyOf`도 마찬가지다.

순서가 있는 `Map`을 읽기 전용으로 넘겨야 한다면 복사 대신 뷰를 쓴다. `Collections.unmodifiableMap(linkedHashMap)`은 원본을 그대로 읽어 들이는 수정 불가 뷰라서 원본의 순회 순서가 그대로 보인다. Java 21부터는 `LinkedHashMap`처럼 순서가 정의된 맵이 `SequencedMap`으로 묶이고, `Collections.unmodifiableSequencedMap`으로 타입에서도 순서를 드러낼 수 있다. 다만 둘 다 복사본이 아니라 뷰이므로 원본 맵을 다른 곳에 넘기거나 계속 수정하면 안 된다.

그래서 응답 객체에서 방어적 복사를 할 때도 순서가 필요한 컬렉션은 순서를 지키는 방법을 고른다.

```java
public record DeptUsageReport(List<DeptUsageRow> rows, Set<String> unmappedDeptCodes) {
    public DeptUsageReport {
        rows = List.copyOf(rows); // List는 순서를 유지한 채 수정 불가 복사본이 된다
        // Set.copyOf는 순회 순서를 보장하지 않으므로 정렬 Set을 감싼다
        unmappedDeptCodes = Collections.unmodifiableSet(new TreeSet<>(unmappedDeptCodes));
    }
}
```

API 응답 형태도 같은 기준으로 고른다. RFC 8259는 JSON 객체를 이름·값 쌍의 순서 없는 모음으로 정의하고, 파서마다 멤버 순서를 드러내는지가 다르다고 적는다. 부서 코드를 키로 한 JSON 객체(`{"D100": {...}}`)에 조직도 순서를 담았다고 기대하면 안 된다는 뜻이다. 순서가 계약이라면 응답은 배열(`List<DeptUsageRow>`)이어야 한다. 그리고 불변 컬렉션은 담긴 원소까지 불변으로 만들지 않는다. 원소를 불변 `record`로 둔 이유다.

## 대안 비교: DB 집계, Stream, 반복문

같은 통계를 DB에서 집계할 수도 있다. 한 달 치 접속 로그가 많다면 원본 행을 전부 애플리케이션으로 가져오는 것보다 DB에서 묶어 결과만 받는 편이 네트워크와 heap 모두에 유리하다.

```sql
SELECT d.dept_code,
       d.dept_name,
       COUNT(l.user_id)          AS access_count,
       COUNT(DISTINCT l.user_id) AS active_users
FROM department d
LEFT JOIN system_usage_log l
       ON l.dept_code = d.dept_code
      AND l.accessed_at >= :fromInclusive
      AND l.accessed_at <  :toExclusive
      AND l.batch_account = 'N'
WHERE d.use_yn = 'Y'
GROUP BY d.dept_code, d.dept_name, d.sort_order
ORDER BY d.sort_order, d.dept_code
```

`LEFT JOIN`과 `COUNT(l.user_id)`를 쓴 이유는 접속이 없던 부서도 0건으로 남기기 위해서다. `GROUP BY`도 결과 순서를 약속하지 않으므로 `ORDER BY`는 반드시 적는다(SQL 결과 순서에 대해서는 [청구서 일괄 조회 글](/posts/postgresql-batch-lookup-order-ordinality/)에서 따로 다뤘다). 정산 금액까지 한 쿼리에서 로그와 함께 `JOIN`해 합산하면 로그 행 수만큼 정산 행이 곱해져 금액이 부풀려진다. 정산은 별도 쿼리나 미리 집계한 서브쿼리로 붙인다.

세 가지 방법을 비교하면 다음과 같다.

| 방법 | 잘 맞는 경우 | 쓰지 말아야 할 때 |
| --- | --- | --- |
| DB `GROUP BY` | 원본 행이 많고, 필요한 데이터가 한 DB에 있을 때 | 조직도처럼 다른 시스템에서 받아 오는 데이터와 합쳐야 할 때, 규칙이 SQL로 표현하기 어렵거나 테스트하기 힘들 때 |
| Stream `groupingBy`/`toMap` | 이미 범위를 줄인 데이터를 여러 출처에서 모아 합칠 때, 규칙을 순수 함수로 테스트하고 싶을 때 | 수십만 건 이상의 원본 행을 그대로 메모리에 올려야 할 때, 행마다 분기·로그·중단이 필요할 때 |
| 반복문 + `Map.merge` | 한 번 순회로 여러 값을 동시에 집계하거나, 행 단위 예외 처리가 필요할 때 | 고르고 바꾸고 모으는 단순한 흐름이라 Stream이 더 잘 읽힐 때 |

반복문 방식은 Stream보다 길지만 행마다 판단이 필요한 경우 디버깅이 쉽다. `Map.merge`는 키가 없으면 값을 넣고, 있으면 주어진 함수로 기존 값과 합친다.

```java
Map<String, BigDecimal> sumByDept = new HashMap<>();
for (SettlementLine line : settlements) {
    if (line.amount() == null) {
        log.warn("정산 금액 누락: dept={}, item={}", line.deptCode(), line.costItem());
        continue;
    }
    sumByDept.merge(line.deptCode(), line.amount(), BigDecimal::add);
}
```

어느 방법을 쓰든 순서를 책임지는 곳은 한 군데여야 한다. DB에서 `ORDER BY`로 정렬했다면 애플리케이션에서 `HashMap`에 다시 담아 순회하는 순간 그 순서는 사라진다.

## 어떻게 확인하나

계약은 테스트로 고정해야 유지된다. 특히 순서 테스트는 입력을 일부러 섞어야 의미가 있다. 입력이 이미 기대 순서대로 들어 있으면 순서를 책임지지 않는 코드도 통과하기 때문이다.

```java
class DeptUsageAggregatorTest {

    private final DeptUsageAggregator aggregator = new DeptUsageAggregator();

    @Test
    void 응답은_조직도_순서를_따르고_접속이_없던_부서도_0으로_남는다() {
        List<Department> departments = new ArrayList<>(List.of(
                new Department("D300", "재무팀", 1),
                new Department("D100", "인사팀", 2),
                new Department("D200", "총무팀", 3)));
        Collections.shuffle(departments, new Random(7)); // 입력 순서에 기대지 않는지 확인

        List<UsageLog> logs = List.of(
                log("D100", "kim"), log("D100", "kim"), log("D100", "lee"), log("D300", "park"));

        DeptUsageReport report = aggregator.summarize(departments, logs, List.of());

        assertThat(report.rows()).extracting(DeptUsageRow::deptCode)
                .containsExactly("D300", "D100", "D200");
        DeptUsageRow hr = report.rows().get(1);
        assertThat(hr.accessCount()).isEqualTo(3);
        assertThat(hr.activeUsers()).isEqualTo(2);              // kim은 한 명으로 센다
        assertThat(report.rows().get(2).accessCount()).isZero(); // 총무팀은 사라지지 않는다
    }

    @Test
    void 부서_코드가_중복되면_덮어쓰지_않고_실패한다() {
        List<Department> departments = List.of(
                new Department("D100", "인사팀", 1), new Department("D100", "인사기획팀", 2));

        assertThatThrownBy(() -> aggregator.summarize(departments, List.of(), List.of()))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("D100");
    }

    @Test
    void 정산_줄은_합산하고_조직도에_없는_코드는_따로_드러낸다() {
        List<Department> departments = List.of(new Department("D100", "인사팀", 1));
        List<SettlementLine> lines = List.of(
                new SettlementLine("D100", "라이선스", new BigDecimal("120000")),
                new SettlementLine("D100", "서버", new BigDecimal("30000")),
                new SettlementLine("D900", "라이선스", new BigDecimal("50000")));

        DeptUsageReport report = aggregator.summarize(departments, List.of(), lines);

        assertThat(report.rows().get(0).settlementAmount()).isEqualByComparingTo("150000");
        assertThat(report.unmappedDeptCodes()).containsExactly("D900");
        assertThatThrownBy(() -> report.rows().add(null))
                .isInstanceOf(UnsupportedOperationException.class);
    }

    private static UsageLog log(String deptCode, String userId) {
        return new UsageLog(deptCode, userId, false, LocalDateTime.of(2026, 8, 3, 9, 0));
    }
}
```

`./gradlew test --tests '*DeptUsageAggregatorTest'`로 이 테스트만 돌릴 수 있다. 금액 비교에 `isEqualByComparingTo`를 쓴 것은 `BigDecimal`의 `equals`가 `150000`과 `150000.00`처럼 scale이 다른 값을 다르게 보기 때문이다.

실패했을 때 처음 볼 곳은 증상마다 다르다.

- 순서가 틀리면: 응답 목록을 무엇을 순회하며 만들었는지 본다. `groupingBy` 결과나 `HashMap`을 순회하고 있다면 그것이 원인이다.
- 합계가 틀리면: merge function이 합산인지 덮어쓰기인지, SQL에서 `JOIN` 때문에 행이 곱해지지 않았는지 본다.
- 운영에서 `IllegalStateException`이 나면: merge function을 바꾸기 전에 기준 데이터 조회 쿼리를 먼저 본다. 겹치는 키는 대부분 조회 조건 누락의 결과다.

운영 로그에는 `dept_count`, `log_count`, `unmapped_dept_codes`처럼 집계 입력과 결과의 개수를 한 줄로 남겨 두면, 숫자가 이상하다는 문의가 왔을 때 데이터 문제인지 코드 문제인지 빨리 가를 수 있다.

## 정리

컬렉션 선택을 코드 리뷰에서 확인할 때 쓸 수 있는 체크리스트다.

- 응답 순서를 책임지는 자료구조가 하나로 정해져 있고, 그것이 `List`나 순서를 보장하는 구현체인가
- `HashMap`, `HashSet`, 기본 `groupingBy` 결과를 순회해 응답을 만들고 있지 않은가
- "이미 본 값인가"를 반복해서 묻는 곳에 `List.contains` 대신 `Set`을 쓰는가
- `toMap`의 merge function이 도메인 의미(오류, 합산, 명시적 선택)를 표현하는가
- 없는 키를 `getOrDefault`로 덮어도 되는 경우와 따로 드러내야 하는 경우를 구분했는가
- 반환 컬렉션이 수정 불가이고, 불변으로 감싸면서 순서를 잃지 않았는가
- 순서가 계약인 API 응답을 JSON 객체가 아니라 배열로 내보내는가
- 원본 행이 많다면 애플리케이션 집계 대신 DB 집계를 검토했는가

## 참고한 공식 문서

- [Oracle Java SE 21 `Collectors`](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/stream/Collectors.html)
- [Oracle Java SE 21 `Stream`](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/stream/Stream.html)
- [Oracle Java SE 21 `Map`](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/Map.html)
- [Oracle Java SE 21 `LinkedHashMap`](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/LinkedHashMap.html)
- [RFC 8259: The JavaScript Object Notation (JSON) Data Interchange Format](https://www.rfc-editor.org/rfc/rfc8259)
