---
title: "청구서 ID 일괄 조회에서 요청 순서 지키기: PostgreSQL IN 대신 unnest WITH ORDINALITY"
date: 2026-08-20 08:55:00 +0900
tags: [Java, PostgreSQL, SQL, Database, Backend]
excerpt: "선택한 청구서를 화면 순서대로 엑셀에 출력할 때 IN 조회가 순서를 보장하지 않는 이유와 PostgreSQL unnest WITH ORDINALITY, Map 재정렬, 누락 ID 처리를 비교한다."
redirect_from:
  - /posts/postgresql-ordinality-product-batch-query/
---

청구 관리 화면에서 담당자가 검색 결과 중 청구서 몇십 건을 체크하고, 확인할 순서대로 끌어 놓은 뒤 "선택 건 엑셀 출력"을 누른다. 화면은 선택된 청구서 ID를 화면에 보이는 순서대로 서버에 보낸다. 서버는 `WHERE invoice_id IN (...)`으로 청구서를 조회해 엑셀을 만든다. 개발 환경에서 몇 건으로 확인할 때는 화면과 같은 순서로 나와서 문제가 없어 보인다.

운영에 나가면 두 종류의 문의가 들어온다. "엑셀 순서가 화면과 다르다", 그리고 "20건을 골랐는데 19건만 나왔다". 둘 다 SQL이 틀려서 생긴 일이 아니다. 요청 순서를 누가 책임지는지, 찾지 못한 청구서를 어떻게 알릴지라는 계약을 코드가 정하지 않았기 때문이다. 이 글은 PostgreSQL을 기준으로 이 두 계약을 SQL과 Java 코드에 옮기는 방법을 정리한다.

> 이 글의 예제는 개념을 설명하기 위해 구성한 코드이며, 특정 서비스의 운영 수치가 아니다.

## 요청 흐름과 먼저 정할 계약

화면이 보내는 요청은 다음과 같다.

```http
POST /api/invoices/export
Content-Type: application/json

{ "invoiceIds": [10452, 10017, 10388, 99999, 10017] }
```

SQL을 고르기 전에 세 가지를 정해야 한다.

1. 순서: 응답과 엑셀의 행 순서는 요청 배열의 순서를 따른다. 이것이 이 기능의 핵심 계약이다.
2. 중복: `10017`이 두 번 왔다. 같은 청구서를 두 줄 출력할 이유가 없다면 첫 등장 위치만 남긴다. 반대로 중복이 수량이나 반복 출력을 뜻하는 기능이라면 중복 제거는 데이터 손실이므로 원본 배열을 그대로 써야 한다.
3. 누락: `99999`는 없거나, 삭제됐거나, 담당자에게 조회 권한이 없는 청구서다. 결과에서 조용히 빼면 "19건만 나왔다"는 문의가 된다. 누락을 알리고 전체를 실패시킬지, 해당 위치에 "조회 불가" 행을 남길지 정한다.

청구서처럼 금액이 오가는 문서는 일부가 빠진 채 출력되는 것이 더 위험하므로, 이 글의 예시는 "중복은 첫 등장만 남기고, 누락이 있으면 누락 ID를 알려 주며 출력을 거절한다"로 정한다. 이 정책이 모든 화면에 맞는 것은 아니며, 중요한 것은 정책이 코드에 드러나는 것이다.

## IN 조회는 왜 순서를 지켜 주지 않나

처음 작성하는 쿼리는 보통 이렇다.

```sql
SELECT invoice_id, invoice_no, customer_name, billing_month, total_amount, status
FROM invoice
WHERE invoice_id IN (10452, 10017, 10388, 99999)
  AND deleted = false;
```

PostgreSQL 문서에서 `IN (값 목록)`은 각 값과의 `=` 비교를 `OR`로 이은 것의 줄임 표현이다. 즉 어떤 행을 남길지 정하는 필터 조건일 뿐, 결과를 어떤 순서로 내보낼지는 아무것도 말하지 않는다. 배열 파라미터를 쓰는 `invoice_id = ANY(?)`도 마찬가지다.

결과 순서에 대해서는 문서가 분명하게 적고 있다. `ORDER BY`로 정렬을 고르지 않으면 행은 정해지지 않은 순서로 반환되며, 실제 순서는 스캔·조인 계획의 종류와 디스크에 저장된 순서에 따라 달라지므로 그 순서에 기대면 안 된다. 출력 순서는 정렬 단계를 명시했을 때만 보장된다.

실제로 순서를 바꾸는 요인은 여러 가지다.

- 실행 계획: 인덱스를 타면 인덱스 키 순서처럼 보이고, 테이블을 순차로 읽으면 저장된 순서처럼 보인다. 통계가 갱신되거나 데이터 양이 바뀌면 계획도 바뀐다.
- 저장 순서의 변화: PostgreSQL에서 `UPDATE`는 새 행 버전을 만든다. 청구 상태를 바꾸는 일이 잦은 테이블이라면 행의 물리적 위치도 계속 바뀐다.
- 동기화된 순차 스캔: `synchronize_seqscans`가 켜져 있으면(기본값 `on`) 큰 테이블의 순차 스캔이 이미 진행 중인 다른 스캔에 맞춰 테이블 중간부터 시작할 수 있다. 문서는 이 때문에 `ORDER BY` 없는 쿼리의 행 순서가 예측할 수 없게 바뀔 수 있다고 적는다.
- `LIMIT`: 플래너는 `LIMIT` 값을 고려해 계획을 세우므로 값에 따라 다른 계획과 다른 순서가 나올 수 있다. 청구 목록 페이징에서 정렬 키가 유일하지 않으면 페이지 사이에 행이 겹치거나 빠지는 이유다.

그래서 "개발 DB에서 몇 번 해 봤더니 순서가 맞았다"는 근거가 되지 못한다. 데이터가 적고 계획이 단순할 때 우연히 맞았을 뿐이다.

ORM이나 매퍼를 거쳐도 사정은 같다. Spring Data의 `CrudRepository.findAllById`는 Javadoc에 결과 원소의 순서를 보장하지 않으며, 찾지 못한 ID에 대해서는 아무 엔티티도 돌려주지 않는다고 적혀 있다. 순서와 누락이라는 두 문제를 그대로 물려받는 셈이다. MyBatis에서 `<foreach>`로 `IN` 목록을 만드는 경우도 결국 같은 SQL이 실행되므로 다르지 않다. 편의 메서드가 순서까지 맞춰 줄 것이라는 기대는 문서로 확인하기 전까지 가정일 뿐이다.

## unnest WITH ORDINALITY로 순서를 데이터로 만든다

순서를 지키려면 "요청 배열에서 몇 번째였는가"를 SQL이 다룰 수 있는 값으로 만들어야 한다. PostgreSQL의 `unnest`는 배열을 원소 순서대로 행 집합으로 펼치고, 테이블 함수에 `WITH ORDINALITY`를 붙이면 1부터 번호를 매긴 `bigint` 열이 추가된다. psql에서 바로 확인할 수 있다.

```sql
SELECT *
FROM unnest(ARRAY[10452, 10017, 10388, 99999]::bigint[]) WITH ORDINALITY AS r(requested_id, ord)
ORDER BY r.ord;

 requested_id | ord
--------------+-----
        10452 |   1
        10017 |   2
        10388 |   3
        99999 |   4
```

이 결과를 청구서 테이블과 조인하고 `ord`로 정렬하면 요청 순서가 SQL의 명시적인 정렬 기준이 된다.

```sql
SELECT r.ord,
       r.requested_id,
       i.invoice_no,
       i.customer_name,
       i.billing_month,
       i.total_amount,
       i.status
FROM unnest(?::bigint[]) WITH ORDINALITY AS r(requested_id, ord)
LEFT JOIN invoice i
       ON i.invoice_id = r.requested_id
      AND i.deleted = false
ORDER BY r.ord;
```

이 쿼리에서 각 줄이 맡은 역할은 다음과 같다.

- `ORDER BY r.ord`는 생략할 수 없다. `ord`는 그저 값이 담긴 열일 뿐이고, 조인 방식에 따라 출력 순서는 얼마든지 바뀔 수 있다. 정렬을 서브쿼리 안에만 두고 바깥에서 다시 조인해도 보장은 사라지므로, 최종 `SELECT`에 둔다.
- `LEFT JOIN`은 찾지 못한 ID도 결과에 남긴다. 청구서가 없으면 `i.*` 열이 `NULL`인 행이 요청 위치 그대로 나오므로, 누락 확인을 같은 쿼리에서 할 수 있다.
- 삭제 여부나 조회 권한 범위 같은 조건은 `ON` 절에 둔다. `WHERE i.deleted = false`로 옮기면 `NULL` 행이 걸러져 사실상 내부 조인이 되고, 누락된 ID가 다시 조용히 사라진다.
- 중복된 원소에도 각각 번호가 붙는다. 중복을 보존해야 하는 기능이라면 원본 배열을 그대로 넘기면 되고, 중복을 없애기로 했다면 바인딩 전에 애플리케이션에서 처리해 SQL을 단순하게 유지한다.
- ID가 몇 개든 파라미터는 배열 하나다. 자리표시자 개수에 따라 SQL 문장이 달라지지 않고, 값을 문자열로 이어 붙일 필요도 없다.

Java에서는 JDBC 배열 하나로 바인딩한다. `JdbcTemplate`에 `PreparedStatementCreator`를 넘기면 커넥션에서 `createArrayOf`로 배열을 만들 수 있다.

```java
public record InvoiceExportRow(long ord, long requestedId, String invoiceNo, String customerName,
                               String billingMonth, BigDecimal totalAmount, String status) {
    public boolean found() {
        return invoiceNo != null; // LEFT JOIN에서 짝이 없으면 청구서 열이 NULL이다
    }
}

@Repository
@RequiredArgsConstructor
public class InvoiceBatchQueryRepository {

    private static final String SQL = """
            SELECT r.ord, r.requested_id,
                   i.invoice_no, i.customer_name, i.billing_month, i.total_amount, i.status
            FROM unnest(?::bigint[]) WITH ORDINALITY AS r(requested_id, ord)
            LEFT JOIN invoice i
                   ON i.invoice_id = r.requested_id
                  AND i.deleted = false
            ORDER BY r.ord
            """;

    private final JdbcTemplate jdbcTemplate;

    public List<InvoiceExportRow> findInRequestedOrder(List<Long> invoiceIds) {
        if (invoiceIds.isEmpty()) {
            return List.of();
        }
        return jdbcTemplate.query(con -> {
            PreparedStatement ps = con.prepareStatement(SQL);
            ps.setArray(1, con.createArrayOf("bigint", invoiceIds.toArray()));
            return ps;
        }, (rs, rowNum) -> new InvoiceExportRow(
                rs.getLong("ord"),
                rs.getLong("requested_id"),
                rs.getString("invoice_no"),
                rs.getString("customer_name"),
                rs.getString("billing_month"),
                rs.getBigDecimal("total_amount"),
                rs.getString("status")));
    }
}
```

Service는 요청 크기 제한, 중복 정책, 누락 정책을 맡는다. 크기 제한은 중복을 없애기 전의 원본 요청에 건다. 그래야 같은 ID를 반복해 보내는 요청으로 제한을 우회할 수 없다.

```java
@Slf4j
@Service
@RequiredArgsConstructor
public class InvoiceExportService {

    private static final int MAX_EXPORT_IDS = 500;

    private final InvoiceBatchQueryRepository repository;

    @Transactional(readOnly = true)
    public List<InvoiceExportRow> loadForExport(List<Long> requestedIds) {
        if (requestedIds.isEmpty() || requestedIds.size() > MAX_EXPORT_IDS) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "선택 건수는 1건 이상 " + MAX_EXPORT_IDS + "건 이하여야 합니다.");
        }
        // 첫 등장 순서를 유지하면서 중복만 없앤다
        List<Long> orderedUniqueIds = List.copyOf(new LinkedHashSet<>(requestedIds));

        List<InvoiceExportRow> rows = repository.findInRequestedOrder(orderedUniqueIds);

        List<Long> missingIds = rows.stream()
                .filter(row -> !row.found())
                .map(InvoiceExportRow::requestedId)
                .toList();
        if (!missingIds.isEmpty()) {
            log.warn("invoice_export_missing requested={} unique={} missing={}",
                    requestedIds.size(), orderedUniqueIds.size(), missingIds.size());
            throw new MissingInvoiceException(missingIds); // 예외 처리기에서 누락 ID 목록을 응답에 담는다
        }
        return rows;
    }
}
```

형식 검증은 Service에 들어오기 전에 끝내 둔다. 요청 배열에 `null`이 섞이면 `List.copyOf`가 `NullPointerException`을 던지고, 검증 없이 SQL까지 내려가더라도 `unnest`가 `NULL` 행을 만든 뒤 조인에 실패한다. 이때 `rs.getLong`은 SQL `NULL`을 0으로 읽기 때문에 응답에는 요청한 적 없는 `0`이라는 ID가 누락 목록에 실려 나간다. 요청 DTO를 `record InvoiceExportRequest(@NotEmpty @Size(max = 500) List<@NotNull @Positive Long> invoiceIds)`처럼 선언하고 Controller에서 `@Valid`로 검증하면, 형식 오류는 400 응답으로 끝나고 Service는 순서·중복·누락이라는 계약 판단에만 집중할 수 있다.

누락 사유를 "없음", "삭제됨", "권한 없음"으로 나눠 알려 주고 싶을 수 있지만, 권한이 없는 청구서의 존재 여부까지 드러내게 되므로 외부 응답에서는 "조회할 수 없는 청구서"로 묶는 편이 안전하다. 사유별 구분은 서버 로그와 내부 지표에서 한다. 요청 ID 원문 전체를 로그에 남기기보다 위 예시처럼 개수를 남기면 로그 양과 노출 범위를 함께 줄일 수 있다.

## 대안: 애플리케이션에서 Map으로 재정렬한다

순서를 DB가 아니라 애플리케이션이 책임지는 방법도 있다. 순서와 무관하게 필요한 행만 조회한 다음, ID를 키로 하는 `Map`을 만들고 요청 순서대로 다시 꺼낸다. Spring의 `NamedParameterJdbcTemplate`은 `List`를 넘기면 `IN` 절의 자리표시자를 개수만큼 만들어 주므로, PostgreSQL 전용 문법 없이 쓸 수 있다.

```java
public List<InvoiceSummary> findInRequestedOrderPortable(List<Long> orderedIds) {
    List<InvoiceSummary> found = namedJdbcTemplate.query("""
            SELECT invoice_id, invoice_no, total_amount
            FROM invoice
            WHERE invoice_id IN (:ids)
              AND deleted = false
            """,
            Map.of("ids", orderedIds),
            (rs, rowNum) -> new InvoiceSummary(
                    rs.getLong("invoice_id"), rs.getString("invoice_no"), rs.getBigDecimal("total_amount")));

    // PK 조회이므로 키가 겹치면 조회 조건이 잘못된 것이다. toMap 기본 동작대로 예외를 낸다
    Map<Long, InvoiceSummary> byId = found.stream()
            .collect(Collectors.toMap(InvoiceSummary::invoiceId, Function.identity()));

    List<Long> missingIds = orderedIds.stream().filter(id -> !byId.containsKey(id)).toList();
    if (!missingIds.isEmpty()) {
        throw new MissingInvoiceException(missingIds);
    }
    return orderedIds.stream().map(byId::get).toList();
}
```

이 방식의 함정은 `filter(Objects::nonNull)` 한 줄로 누락을 처리하고 끝내기 쉽다는 점이다. 그러면 누락 정책을 아무도 결정하지 않은 채 "조용히 빼기"가 정책이 된다. 위 코드처럼 누락을 먼저 계산해 명시적으로 다룬다. Spring 문서는 JDBC 표준이 `IN` 목록에 100개를 넘는 값을 보장하지 않으며, DB마다 허용 개수에 상한이 있다고 경고한다(예로 Oracle의 1000개를 든다). 이 방식에도 요청 크기 제한은 똑같이 필요하다.

두 방식 외에도 몇 가지 선택지가 있다. 함께 비교하면 다음과 같다.

| 방법 | 잘 맞는 경우 | 쓰지 말아야 할 때 |
| --- | --- | --- |
| `unnest ... WITH ORDINALITY` + `ORDER BY` | PostgreSQL을 쓰고, 조회 결과를 순서대로 바로 출력하는 경우. 누락도 같은 쿼리에서 확인 | DB가 PostgreSQL이 아니거나 이식성이 중요할 때, ID가 수천 건 이상이라 배열 전개와 정렬 비용이 커질 때 |
| `IN` 조회 + Java `Map` 재정렬 | 여러 DB를 지원해야 하거나, 다른 시스템의 데이터와 합친 뒤 순서를 맞춰야 할 때 | 조회 결과를 메모리에 모두 모으기 부담스러울 만큼 클 때, `IN` 목록 상한을 넘길 때 |
| `ORDER BY array_position(?, invoice_id)` | 목록이 작고 중복이 없는 간단한 조회 | 중복을 보존해야 할 때(첫 위치만 돌려준다), 목록이 길 때(행마다 배열을 검색한다) |
| 검색 조건을 다시 보내 서버에서 재조회 | 사용자가 "검색 결과 전체"를 출력하는 경우. 같은 조건과 같은 정렬 키로 서버가 다시 조회 | 순서를 사용자가 직접 정했거나, 다른 시스템이 정한 순서일 때 |

`ORDER BY CASE invoice_id WHEN ... THEN 1 ...`처럼 요청 순서를 SQL 문자열에 직접 펼치는 방법도 있지만, 요청마다 SQL이 달라지고 문자열 조립 실수가 끼어들기 쉬워 권하지 않는다.

검색 조건을 다시 보내는 방식을 고를 때는 정렬 키가 유일한지 확인해야 한다. 화면이 `ORDER BY billing_month DESC`로만 정렬돼 있다면 같은 달에 발행된 청구서끼리의 순서는 정해져 있지 않다. 같은 조건으로 다시 조회해도 그 안의 순서는 화면과 다를 수 있고, `LIMIT`/`OFFSET`으로 나눠 읽는 페이징이라면 페이지 사이에서 행이 겹치거나 빠질 수도 있다. PostgreSQL 문서도 `LIMIT`을 쓸 때는 결과 행을 유일한 순서로 고정하는 `ORDER BY`를 쓰라고 권한다. 마지막 정렬 키에 PK를 덧붙이면 해결된다.

```sql
-- 같은 달 청구서끼리의 순서를 PK로 고정해, 화면과 엑셀이 같은 순서를 재현하게 한다
SELECT invoice_id, invoice_no, customer_name, billing_month, total_amount, status
FROM invoice
WHERE customer_name LIKE :customerPrefix
  AND billing_month BETWEEN :fromMonth AND :toMonth
  AND deleted = false
ORDER BY billing_month DESC, invoice_id DESC;
```

요청 ID가 많을 때의 비용도 따져 봐야 한다. `WITH ORDINALITY` 방식에서는 요청 건수만큼 배열이 행으로 펼쳐지고, 그만큼 조인과 정렬이 일어난다. 수백 건 수준이라면 PK 조회와 작은 정렬이라 부담이 거의 없지만, 화면에서 수천 건을 골라 보내는 기능이라면 먼저 기능의 모양을 다시 본다. 사용자가 고른 것이 사실상 "검색 결과 전체"라면 ID 목록 대신 검색 조건을 받는 편이 요청 크기와 DB 작업량 모두에서 낫다. ID 목록이 꼭 필요하다면 상한을 두고, 상한을 넘는 요청은 일정 크기로 잘라 순서대로 조회한 뒤 이어 붙인다. 각 조각이 요청 순서를 지키므로 조각을 처리한 순서대로 붙이기만 하면 전체 순서도 유지된다. 이때 누락 확인과 중복 제거는 조각 단위가 아니라 전체 요청 단위로 해야 한다.

엑셀 출력과 연결하면 차이가 하나 더 생긴다. `WITH ORDINALITY` 쿼리는 결과가 이미 요청 순서로 나오므로 `ResultSet`을 한 행씩 읽어 SXSSF 시트에 바로 쓸 수 있다. 반면 `Map` 재정렬은 모든 행을 메모리에 모은 뒤에야 순서를 맞출 수 있다. 수백 건이면 차이가 없지만, 출력 대상이 커질수록 앞의 방식이 메모리 면에서 유리하다. 스트리밍 출력은 [대용량 엑셀 다운로드 글](/posts/jvm-memory-areas-spring-diagnosis/)에서 다뤘다. 다른 DBMS에서는 배열 파라미터와 위치 번호를 다루는 문법이 달라서 같은 SQL을 그대로 쓸 수 없으며, 그때는 `Map` 재정렬이 가장 이식성 있는 선택이다.

## 어떻게 확인하나

이 쿼리는 PostgreSQL 문법에 기대고 있으므로 H2 같은 대체 DB가 아니라 실제 PostgreSQL에서 확인해야 한다. Spring Boot 3.1 이상이라면 Testcontainers와 `@ServiceConnection`으로 테스트용 PostgreSQL을 띄울 수 있다(`spring-boot-testcontainers`, `org.testcontainers:postgresql` 의존성 필요). 대체 DB로 통과한 테스트가 실제 DB에서 깨지는 문제는 [Testcontainers 글](/posts/testcontainers-database-migration-parity/)에서 따로 다뤘다.

```java
@JdbcTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Testcontainers
@Import(InvoiceBatchQueryRepository.class)
@Sql(statements = {
        "CREATE TABLE invoice (invoice_id bigint PRIMARY KEY, invoice_no varchar(20) NOT NULL, "
                + "customer_name varchar(100), billing_month char(7), total_amount numeric(15, 2), "
                + "status varchar(20), deleted boolean NOT NULL DEFAULT false)",
        "INSERT INTO invoice (invoice_id, invoice_no, customer_name, billing_month, total_amount, status) "
                + "SELECT g, 'INV-' || g, '고객사-' || g, '2026-08', g * 1000, 'ISSUED' "
                + "FROM generate_series(1, 5000) AS g",
        "UPDATE invoice SET deleted = true WHERE invoice_id = 4000"
})
class InvoiceBatchQueryRepositoryTest {

    @Container
    @ServiceConnection
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine");

    @Autowired
    InvoiceBatchQueryRepository repository;

    @Test
    void 요청한_순서대로_반환하고_조회할_수_없는_청구서도_제자리에_남긴다() {
        List<Long> requested = List.of(3021L, 17L, 4000L, 999_999L, 1250L, 17L);

        List<InvoiceExportRow> rows = repository.findInRequestedOrder(requested);

        assertThat(rows).extracting(InvoiceExportRow::requestedId)
                .containsExactly(3021L, 17L, 4000L, 999_999L, 1250L, 17L); // 정렬된 ID 순서가 아니다
        assertThat(rows).extracting(InvoiceExportRow::found)
                .containsExactly(true, true, false, false, true, true);  // 삭제된 4000, 없는 999999
    }
}
```

요청 ID를 일부러 오름차순이 아닌 순서로 넣었고, 삭제된 ID와 존재하지 않는 ID, 중복 ID를 모두 섞었다. 테이블에는 ID 오름차순으로 데이터를 넣었으므로, 정렬 책임이 쿼리에 없다면 "ID 순서로 나오는" 실패를 보게 된다. Repository 단계에서는 중복이 그대로 두 번 나오는 것이 맞다. 중복 제거는 Service의 정책이기 때문이다.

DB에서 직접 확인할 때는 psql에서 다음 순서로 본다.

1. 위의 리터럴 배열 예제로 `ord`가 요청 순서대로 붙는지 확인한다.
2. `IN` 버전 쿼리를 같은 ID로 실행해 결과 순서가 요청 순서와 어떻게 다른지 본다. 순서가 실행 계획을 따라간다는 것을 눈으로 확인하는 단계다.
3. `EXPLAIN (ANALYZE, BUFFERS)`를 `WITH ORDINALITY` 쿼리 앞에 붙여 실행하고, 조인 방식과 마지막 `Sort` 노드의 정렬 키가 `r.ord`인지, 실제 처리 행 수가 요청 건수와 비슷한지 본다.

순서가 어긋났다는 문의가 오면 가장 먼저 볼 곳은 최종 `SELECT`에 `ORDER BY r.ord`가 남아 있는지다. 리팩터링 중에 쿼리를 서브쿼리로 감싸면서 바깥에 정렬을 빠뜨리는 경우가 흔하다. 그다음은 Service가 원본 목록과 중복 제거한 목록 중 어느 것을 바인딩했는지다. 건수가 모자란다는 문의라면 청구서 조건이 `ON` 대신 `WHERE`로 옮겨 가지 않았는지, 누락 정책이 예외가 아니라 `filter`로 바뀌지 않았는지 본다.

## 정리

여러 ID를 한 번에 조회해 순서대로 보여 주는 기능을 리뷰할 때 확인할 항목이다.

- 응답 순서가 요청 순서라는 계약이 문서와 코드에 드러나 있는가
- 결과 순서를 `IN` 조회나 테이블 저장 순서에 기대지 않고, 최종 `SELECT`의 `ORDER BY`나 애플리케이션의 재정렬로 명시했는가
- 중복 ID가 의미 있는지 정했고, 중복 제거는 첫 등장 순서를 유지하는가
- 찾지 못한 ID를 조용히 빼지 않고, 실패 또는 표시로 명시적으로 다루는가
- `LEFT JOIN`을 쓸 때 대상 테이블 조건을 `ON` 절에 두었는가
- 요청 크기 상한을 중복 제거 전 원본 기준으로 검사하고, `null` 같은 형식 오류는 Controller 검증에서 걸러 내는가
- 검색 조건으로 재조회한다면 정렬 키 마지막에 PK 같은 유일한 열을 두었는가
- 순서 테스트가 실제 PostgreSQL에서, 정렬되지 않은 요청과 누락·중복 ID를 섞어 실행되는가

## 참고한 공식 문서

- [PostgreSQL 문서: Table Expressions (`WITH ORDINALITY`)](https://www.postgresql.org/docs/current/queries-table-expressions.html)
- [PostgreSQL 문서: Sorting Rows (`ORDER BY`)](https://www.postgresql.org/docs/current/queries-order.html)
- [PostgreSQL 문서: Version and Platform Compatibility (`synchronize_seqscans`)](https://www.postgresql.org/docs/current/runtime-config-compatible.html)
- [Spring Framework 문서: JDBC Parameter and Data Value Handling (IN 절 목록 전달)](https://docs.spring.io/spring-framework/reference/data-access/jdbc/parameter-handling.html)
- [Spring Data Commons Javadoc: `CrudRepository.findAllById`](https://docs.spring.io/spring-data/commons/reference/api/java/org/springframework/data/repository/CrudRepository.html)
