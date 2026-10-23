---
title: "대용량 엑셀 다운로드가 OOM으로 죽을 때 -Xmx보다 먼저 JVM 메모리 영역을 나눠 봐야 하는 이유"
date: 2026-08-14 22:55:00 +0900
tags: [Java, JVM, Spring Boot, Performance, Operations, Backend]
excerpt: "정산 내역 XLSX 다운로드 API가 OOM으로 죽는 상황을 예로 Heap·Metaspace·스레드 스택·Direct 메모리를 구분하고, POI XSSF와 SXSSF 차이, JVM 옵션, jcmd·jstat 확인 순서를 정리한다."
---

월말 정산 마감 즈음, 운영 담당자가 관리 화면에서 "정산 내역 엑셀 다운로드"를 누른다. 조회 기간을 한 달로, 부서를 전체로 고르면 수십만 행에 수십 개 열이 붙은 XLSX 파일이 만들어진다. 평소에는 조금 기다리면 내려오던 파일이 여러 담당자가 동시에 누른 날에는 응답 없이 멈추고, WAS 로그에 `java.lang.OutOfMemoryError`가 찍히거나 아무 로그도 없이 프로세스가 사라진다.

이때 가장 먼저 나오는 조치는 `-Xmx`를 올리는 것이다. 그날은 넘어갈 수 있지만, 다음 달 데이터가 늘거나 다운로드가 더 겹치면 같은 장애가 돌아온다. 더 나쁜 경우에는 부족했던 곳이 heap이 아니었는데 heap만 키워서 heap 밖 여유를 오히려 줄인다. 이 글은 엑셀 다운로드 API 하나를 따라가며 JVM이 쓰는 메모리를 영역별로 나누고, 어느 영역이 문제인지 확인한 다음 고치는 순서를 정리한다.

> 이 글의 예제는 개념을 설명하기 위해 구성한 코드이며, 특정 서비스의 운영 수치가 아니다.

## 다운로드 요청 하나가 메모리를 쓰는 경로

처음 만든 다운로드 기능은 보통 아래와 비슷하다. 조회 결과를 전부 `List`로 받고, `XSSFWorkbook`에 행을 채운 뒤 응답 스트림에 쓴다. 데이터가 적을 때는 아무 문제가 없어서 오래 살아남는 코드다.

```java
@GetMapping("/api/settlements/excel")
public void download(@RequestParam @DateTimeFormat(pattern = "yyyy-MM") YearMonth month,
                     HttpServletResponse response) throws IOException {
    // 1) 한 달 치 정산 행 전체가 DTO 목록으로 heap에 올라온다
    List<SettlementRow> rows = settlementMapper.findAllByMonth(month);

    // 2) 워크북 전체가 메모리 객체로 만들어진다
    try (XSSFWorkbook workbook = new XSSFWorkbook()) {
        Sheet sheet = workbook.createSheet("정산내역");
        int rowIndex = 0;
        for (SettlementRow r : rows) {
            Row row = sheet.createRow(rowIndex++);
            row.createCell(0).setCellValue(r.settlementNo());
            row.createCell(1).setCellValue(r.deptName());
            row.createCell(2).setCellValue(r.amount().doubleValue());
            // ... 열이 수십 개 이어진다
        }
        response.setContentType("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
        // 3) 이 시점에야 시트 XML을 만들고 ZIP으로 압축해 내보낸다
        workbook.write(response.getOutputStream());
    }
}
```

이 요청이 메모리를 쓰는 곳을 순서대로 적으면 이렇다.

1. Mapper가 반환한 `List<SettlementRow>`에는 행마다 DTO, 문자열, `BigDecimal` 객체가 들어 있다. 모두 heap에 있다.
2. `XSSFWorkbook`은 행과 셀을 객체로 만들어 통합문서 전체를 메모리에 들고 있다. 행을 채우는 루프 동안에는 `rows`가 DTO 목록 전체를 참조하고 있으므로, 루프가 끝나는 순간 DTO 목록과 완성된 워크북이 동시에 heap에 있다. 메모리 사용량이 가장 높은 지점이다.
3. `write()`가 호출되면 시트 내용을 XML로 직렬화하고 ZIP으로 압축해 응답에 쓴다. 이 과정에도 버퍼가 필요하다.
4. 이 모든 일이 WAS의 요청 처리 스레드 하나 위에서 오래 진행된다. 다운로드가 겹친 만큼 1~3이 곱해지고, 붙잡힌 스레드 수도 늘어난다.

결국 이 코드의 메모리 사용량은 "행 수 × 열 수 × 동시 다운로드 수"에 비례한다. `-Xmx`를 올리면 무너지는 지점이 조금 뒤로 밀릴 뿐 비례 관계는 그대로다. 파일을 `ResponseEntity<byte[]>`로 돌려주려고 `ByteArrayOutputStream`에 먼저 쓰는 변형도 흔한데, 이 경우 완성된 파일 크기만큼의 배열이 heap에 하나 더 생기고 `toByteArray()`가 그 배열을 한 번 더 복사한다.

## OOM 메시지로 영역부터 구분한다

"메모리가 부족하다"는 말을 "어느 영역이 부족한가"로 바꾸는 것이 첫 단계다. HotSpot JVM 기준으로 엑셀 다운로드와 관련 있는 영역을 정리하면 다음과 같다.

| 영역 | 들어가는 것 | 상한을 정하는 옵션 | 부족할 때 보이는 것 | 다운로드 기능에서 키우는 요인 |
| --- | --- | --- | --- | --- |
| Heap | 객체와 배열 | `-Xmx` (`-XX:MaxHeapSize`와 같음) | `OutOfMemoryError: Java heap space`, `GC overhead limit exceeded` | 전체 행 `List`, XSSF 워크북, `byte[]` 버퍼 |
| Metaspace | 로드된 클래스의 메타데이터 | `-XX:MaxMetaspaceSize` (기본은 제한 없음) | `OutOfMemoryError: Metaspace` | 다운로드 자체보다 WAS 재기동 없는 반복 재배포 |
| 스레드 스택 | 스레드별 호출 프레임과 지역 변수 | `-Xss` (Linux x64 기본 1024KB) | 깊은 재귀는 `StackOverflowError`, 스레드 생성 실패는 `unable to create native thread` | 오래 걸리는 다운로드가 요청 스레드를 붙잡음 |
| Direct buffer | NIO direct buffer | `-XX:MaxDirectMemorySize` (지정하지 않으면 JVM이 정함) | 메시지에 `direct buffer memory` 문구 | NIO 기반 I/O 라이브러리의 버퍼 |
| 그 밖의 native | JIT 코드 캐시, GC 자료구조, 네이티브 라이브러리 할당 | 영역마다 다름, 결국 OS와 컨테이너 한도 | Java 로그 없이 OS나 컨테이너가 프로세스를 종료 | 위 영역들의 합이 서버 한도를 넘음 |

표에서 기억할 점은 세 가지다.

첫째, `-Xmx`는 heap의 상한이지 프로세스 전체의 상한이 아니다. 서버 메모리에서 heap을 뺀 나머지가 metaspace, 스레드 스택, 코드 캐시, direct buffer, 그리고 같은 서버의 다른 프로세스 몫이다. 한 서버에 WAS 인스턴스를 여러 개 띄운다면 인스턴스마다 이 합을 따로 계산해야 한다.

둘째, `Java heap space`가 곧 메모리 누수라는 뜻은 아니다. Oracle 문제 해결 가이드도 이 메시지가 단순한 설정 문제일 수 있다고 설명한다. 엑셀 다운로드에서는 누수보다 "요청 하나가 처리 중에 너무 많은 객체를 동시에 살려 두는 설계"인 경우가 많다. 요청이 끝나면 회수되지만, 끝나기 전에 heap이 먼저 바닥난다.

셋째, Java 쪽 로그가 하나도 없이 프로세스가 사라졌다면 JVM 안에서 `OutOfMemoryError`가 난 것이 아니라 바깥에서 종료됐을 가능성을 먼저 본다. Linux OOM killer나 컨테이너 메모리 한도가 대표적이다. 이 경우 heap dump는 생기지 않으며, heap 그래프가 여유 있어 보여도 프로세스 전체 메모리는 한도에 닿았을 수 있다.

Metaspace는 다운로드 기능과 직접 관련이 적지만 WAS를 운영하면 자주 마주친다. 재기동 없이 애플리케이션을 반복 재배포하면 이전 클래스로더가 회수되지 않고 클래스 메타데이터가 쌓이는 경우가 있다. 기본값은 제한이 없어서 조용히 native 메모리를 잠식하므로, 평소 사용량을 관찰한 뒤 여유를 두고 `-XX:MaxMetaspaceSize`를 정해 두면 문제가 `Metaspace`라는 분명한 메시지로 드러난다.

## XSSF가 heap을 채우는 방식과 SXSSF가 바꾸는 것

Apache POI의 `XSSFWorkbook`은 통합문서 전체를 메모리 객체로 들고 있다가 `write()` 시점에 파일로 만든다. 그래서 어떤 행이든 언제든 다시 꺼내 고칠 수 있지만, 메모리는 시트 크기에 비례해 늘어난다.

`SXSSFWorkbook`은 POI 문서의 표현으로 heap이 제한된 상황에서 매우 큰 스프레드시트를 만들기 위한 XSSF의 스트리밍 확장이다. 핵심은 sliding window다. 메모리에는 최근 행 일정 개수만 남기고(기본 100행, `SXSSFWorkbook.DEFAULT_WINDOW_SIZE`), 창을 벗어난 행은 디스크의 임시 파일로 내려보낸다. 내려간 행은 `getRow()`로 다시 꺼낼 수 없다. 메모리 사용량이 전체 행 수가 아니라 창 크기에 묶이는 이유다.

대신 SXSSF에는 지켜야 할 조건과 비용이 있다.

- 임시 파일은 시트마다 하나씩 생기고 크기가 꽤 커질 수 있다. 기본적으로 JVM 임시 디렉터리 아래에 쓰이므로 WAS 서버의 디스크 여유를 같이 봐야 한다. `setCompressTempFiles(true)`로 gzip 압축을 켤 수 있지만 그만큼 CPU를 더 쓴다.
- 임시 파일은 `dispose()`로 직접 지워야 한다. 예외가 나도 지워지도록 `finally`에서 호출한다.
- 기본은 shared strings table 대신 inline string을 쓴다. shared strings를 켜면 고유 문자열 전체가 메모리에 남는다. 병합 셀, 하이퍼링크, 메모도 메모리에 남으므로 많이 쓰면 이점이 줄어든다.
- 이미 내려간 행을 다시 볼 수 없으므로 "전체 행을 보고 열 너비를 맞추는" 식의 기능은 제약이 있다. SXSSF는 쓰기 전용 도구이며, 큰 파일을 읽는 문제는 다른 API로 풀어야 한다.

여기서 자주 놓치는 점이 있다. 워크북만 SXSSF로 바꾸고 조회는 그대로 `List`로 받으면, 워크북 쪽 메모리는 줄어도 DTO 목록이 여전히 heap을 채운다. 원본 데이터도 스트리밍으로 읽어야 효과가 난다. `JdbcTemplate`의 `RowCallbackHandler`나 MyBatis의 `ResultHandler`처럼 한 행씩 받아 바로 쓰는 방식을 쓰고, fetch size로 한 번에 가져올 행 수를 정한다. fetch size가 실제로 나눠 읽기로 동작하는 조건은 JDBC 드라이버마다 다르므로 사용하는 드라이버 문서에서 확인해야 한다.

```java
@Service
@RequiredArgsConstructor
public class SettlementExcelExporter {

    private static final int ROW_ACCESS_WINDOW = 100;
    private static final int FETCH_SIZE = 1_000;
    private static final String SQL = """
            SELECT s.settlement_no, d.dept_name, s.cost_item, s.amount, s.settled_at
            FROM settlement s
            JOIN department d ON d.dept_code = s.dept_code
            WHERE s.settle_month = ?
            ORDER BY s.settlement_no
            """;

    private final JdbcTemplate jdbcTemplate;

    @Transactional(readOnly = true)
    public void export(YearMonth month, OutputStream out) throws IOException {
        SXSSFWorkbook workbook = new SXSSFWorkbook(ROW_ACCESS_WINDOW);
        workbook.setCompressTempFiles(true);
        try {
            SXSSFSheet sheet = workbook.createSheet("정산내역");
            writeHeader(sheet.createRow(0));
            int[] rowIndex = {1};

            jdbcTemplate.query(con -> {
                PreparedStatement ps = con.prepareStatement(
                        SQL, ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY);
                ps.setFetchSize(FETCH_SIZE);
                ps.setString(1, month.toString());
                return ps;
            }, (RowCallbackHandler) rs -> {
                // DTO 목록을 만들지 않고 한 행씩 바로 셀로 옮긴다
                Row row = sheet.createRow(rowIndex[0]++);
                row.createCell(0).setCellValue(rs.getString("settlement_no"));
                row.createCell(1).setCellValue(rs.getString("dept_name"));
                row.createCell(2).setCellValue(rs.getString("cost_item"));
                row.createCell(3).setCellValue(rs.getBigDecimal("amount").doubleValue());
                row.createCell(4).setCellValue(rs.getTimestamp("settled_at").toLocalDateTime());
            });

            workbook.write(out);
        } finally {
            workbook.dispose(); // 디스크 임시 파일 삭제
            workbook.close();
        }
    }

    private void writeHeader(Row header) {
        String[] titles = {"정산번호", "부서", "비용항목", "금액", "정산일시"};
        for (int i = 0; i < titles.length; i++) {
            header.createCell(i).setCellValue(titles[i]);
        }
    }
}
```

Controller는 파일 이름과 Content-Type만 정하고 응답 스트림을 넘긴다. 바이트 배열을 만들지 않으므로 완성된 파일 크기만큼의 heap을 따로 쓰지 않는다.

```java
@GetMapping("/api/settlements/excel")
public void download(@RequestParam @DateTimeFormat(pattern = "yyyy-MM") YearMonth month,
                     HttpServletResponse response) throws IOException {
    ContentDisposition disposition = ContentDisposition.attachment()
            .filename("정산내역_" + month + ".xlsx", StandardCharsets.UTF_8)
            .build();
    response.setContentType("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
    response.setHeader(HttpHeaders.CONTENT_DISPOSITION, disposition.toString());
    exporter.export(month, response.getOutputStream());
}
```

한 가지 더 정해 둘 것은 XLSX의 시트당 최대 행 수(1,048,576행)다. 이 한도를 넘을 수 있는 조회라면 시트를 나누거나 CSV, 기간 분할 다운로드처럼 형식 자체를 다시 정해야 한다. 메모리 문제를 해결해도 파일 형식의 한도는 그대로 남는다.

## 실패했을 때 증거가 남도록 기동 옵션을 정한다

코드를 고쳐도 다음 장애는 다른 곳에서 올 수 있다. 그때 "재기동했더니 괜찮아졌다"로 끝나지 않으려면, 실패 순간의 증거가 남도록 WAS 기동 옵션을 미리 정해 둔다. 아래는 기동 스크립트에서 `JAVA_OPTS`를 구성하는 예시다. 값 자체는 서버 메모리와 인스턴스 수에 맞춰 정해야 한다.

```bash
# heap: 서버 배포에서는 -Xms와 -Xmx를 같은 값으로 두는 경우가 많다
JAVA_OPTS="$JAVA_OPTS -Xms2g -Xmx2g"

# metaspace: 평소 사용량을 관찰한 뒤 여유를 두고 상한을 둔다
JAVA_OPTS="$JAVA_OPTS -XX:MaxMetaspaceSize=512m"

# OOM 순간의 heap을 파일로 남긴다 (경로의 디스크 여유와 접근 권한을 먼저 확인)
JAVA_OPTS="$JAVA_OPTS -XX:+HeapDumpOnOutOfMemoryError"
JAVA_OPTS="$JAVA_OPTS -XX:HeapDumpPath=/var/dumps/settlement-api"

# GC 로그를 회전 파일로 남긴다
JAVA_OPTS="$JAVA_OPTS -Xlog:gc*:file=/var/log/settlement-api/gc.log:time,uptime,level,tags:filecount=5,filesize=20M"
```

`-XX:+HeapDumpOnOutOfMemoryError`는 기본으로 꺼져 있다. 켜 두면 `OutOfMemoryError`가 발생할 때 HPROF 형식의 heap dump를 남기며, 경로를 지정하지 않으면 작업 디렉터리에 `java_pid<pid>.hprof`로 만든다. 운영에서 이 옵션을 켤 때는 두 가지를 먼저 확인한다. dump 파일은 heap 크기에 가까울 만큼 클 수 있으므로 해당 경로에 디스크 여유가 있어야 한다. 그리고 dump에는 정산 금액이나 부서 정보처럼 메모리에 있던 업무 데이터가 그대로 들어가므로, 접근 권한과 보관 기간을 정해야 한다.

OOM이 났을 때 로그에는 대략 이런 순서로 남는다. 괄호 안의 값은 환경마다 다르다.

```text
java.lang.OutOfMemoryError: Java heap space
Dumping heap to /var/dumps/settlement-api/java_pid<pid>.hprof ...
Heap dump file created [<size> bytes in <elapsed> secs]
```

GC 로그는 OOM 직전에 GC 후에도 old 영역이 내려오지 않았는지 보는 근거가 된다. 읽는 법은 [JVM GC 로그 글](/posts/jvm-gc-log-latency-analysis/)에서 따로 다뤘다. 반대로 Native Memory Tracking(`-XX:NativeMemoryTracking=summary`)은 상시 옵션으로 두지 않는다. Oracle 문서는 NMT를 켜면 5~10% 정도 성능이 떨어질 수 있다고 안내하므로, heap 밖이 의심될 때 재현 환경에서만 켠다. NMT는 JNI 코드처럼 JVM 바깥에서 직접 할당한 메모리는 추적하지 못한다는 점도 기억해 둔다.

## 어떻게 확인하나

장애가 났거나 재현 중일 때는 아래 순서로 범위를 좁힌다. `jcmd`와 `jstat`는 대상 JVM과 같은 서버에서, JVM을 띄운 것과 같은 사용자 권한으로 실행해야 한다.

```bash
# 1. 대상 JVM을 찾고, 실제로 적용된 옵션을 확인한다
jcmd -l
jcmd <pid> VM.flags

# 2. 다운로드를 누르는 동안 1초 간격으로 GC 상태를 본다
#    O: old 영역 사용률, M: metaspace 사용률, FGC: full GC 횟수
jstat -gcutil <pid> 1000

# 3. 영역별로 한 번 더 확인한다
jcmd <pid> GC.heap_info
jcmd <pid> VM.metaspace
jcmd <pid> Thread.print | grep -c '^"'

# 4. heap 밖이 의심되면 (NMT를 켜고 기동한 재현 환경에서)
jcmd <pid> VM.native_memory summary

# 5. Java 로그 없이 프로세스가 사라졌다면 OS 기록을 본다 (root 권한 필요할 수 있음)
dmesg -T | grep -i -E 'killed process|out of memory'
```

1번에서 `VM.flags`를 보는 이유는 기동 스크립트가 여러 단계로 옵션을 덧붙이는 WAS 환경에서는 생각한 값과 실제 값이 다를 수 있기 때문이다. 2번에서 다운로드 중 `O`가 계속 오르고 `FGC`가 늘어나는데도 내려오지 않으면 heap에 살아 있는 객체가 너무 많다는 뜻이다. `M`이 상한 근처라면 metaspace를 의심한다. 3번에서 스레드 수가 다운로드 횟수만큼 늘었다면 스레드 스택과 요청 스레드 점유도 함께 봐야 한다. 스레드 상태를 읽는 법은 [스레드 덤프 글](/posts/jvm-thread-dump-first-pass/)에 정리했다.

로컬에서는 heap을 일부러 작게 잡고 같은 다운로드를 호출해 본다. 수정 전 코드와 수정 후 코드를 같은 데이터로 비교하면 차이가 분명히 보인다.

```bash
java -Xmx256m -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=./dumps \
     -jar build/libs/settlement-api.jar

curl -s -o settlement.xlsx -w '%{http_code} %{size_download}\n' \
     "http://localhost:8080/api/settlements/excel?month=2026-08"
```

SXSSF가 정말 창 크기만큼만 메모리에 두는지는 테스트로 고정해 둔다. POI 문서의 예제와 같은 원리로, 창을 넘은 행은 `getRow()`가 `null`을 돌려줘야 한다.

```java
class SettlementSheetWindowTest {

    @Test
    void 창을_벗어난_행은_임시_파일로_내려가고_메모리에서_조회되지_않는다() throws Exception {
        SXSSFWorkbook workbook = new SXSSFWorkbook(100);
        Path file = Files.createTempFile("settlement-", ".xlsx");
        try {
            SXSSFSheet sheet = workbook.createSheet("정산내역");
            for (int i = 0; i < 1_000; i++) {
                sheet.createRow(i).createCell(0).setCellValue("STL-" + i);
            }

            assertThat(sheet.getRow(0)).isNull();       // 이미 디스크로 flush됨
            assertThat(sheet.getRow(899)).isNull();
            assertThat(sheet.getRow(900)).isNotNull();  // 마지막 100행만 메모리에 남음

            try (OutputStream out = Files.newOutputStream(file)) {
                workbook.write(out);
            }
            try (XSSFWorkbook written = new XSSFWorkbook(file.toFile())) {
                assertThat(written.getSheetAt(0).getLastRowNum()).isEqualTo(999);
            }
        } finally {
            workbook.dispose();
            workbook.close();
            Files.deleteIfExists(file);
        }
    }
}
```

실패했을 때 가장 먼저 볼 곳은 OOM 메시지 한 줄과 heap dump 파일이 생겼는지 여부다. dump가 있다면 Eclipse MAT 같은 도구로 열어 가장 많은 메모리를 붙잡은 객체를 본다. 상위에 DTO `List`가 있으면 조회가 스트리밍되지 않은 것이고, POI 행·셀 객체가 많으면 아직 XSSF를 쓰거나 창 크기를 `-1`(제한 없음)로 둔 것이며, 큰 `byte[]`가 있으면 어딘가에서 파일 전체를 버퍼에 담고 있는 것이다. 메시지가 heap이 아니라면 heap dump는 답을 주지 못하므로 앞의 표에서 해당 영역으로 돌아간다.

## 해결책 비교: 무엇을 언제 쓰지 말아야 하나

| 방법 | 잘 맞는 경우 | 쓰지 말아야 할 때 |
| --- | --- | --- |
| `-Xmx` 증설 | 설계는 적절한데 heap이 실제 필요량보다 작게 잡힌 경우, 원인 수정 전 임시 완화 | 메모리가 행 수에 비례해 늘어나는 코드, OOM 메시지가 heap이 아닌 경우, 서버에 heap 밖 여유가 없는 경우 |
| SXSSF + 조회 스트리밍 | 목록형 시트를 위에서 아래로 한 번에 써 내려가는 다운로드 | 이미 쓴 행을 다시 고쳐야 하는 양식, 병합 셀·메모가 아주 많은 문서, 큰 파일을 읽는 기능 |
| CSV 다운로드 | 서식이 필요 없고 다른 시스템이 다시 읽어 갈 데이터 | 사용자가 숫자 서식·여러 시트·열 너비를 기대하는 화면. 엑셀에서 한글이 깨지지 않게 인코딩 처리도 따로 해야 함 |
| 비동기 생성 후 다운로드 | 생성에 수 분이 걸려 WAS나 프록시의 타임아웃을 넘기는 경우 | 몇 초 안에 끝나는 작은 파일. 작업 상태 조회, 파일 보관·삭제, 다운로드 권한 확인이 새로 생긴다 |

`-Xmx` 증설은 틀린 조치가 아니라 범위가 좁은 조치다. heap 사용량이 일정 수준에서 안정되고 단지 상한이 그보다 낮았다면 올리는 것이 맞다. 하지만 행 수에 비례해 늘어나는 구조라면 다음 달에 다시 같은 회의를 하게 된다.

SXSSF는 요청 하나의 메모리를 창 크기에 묶어 주지만, 동시 다운로드 수까지 묶어 주지는 않는다. 다운로드가 몰리는 시점에는 DB 커서, 임시 파일, 요청 스레드가 다운로드 수만큼 늘어난다. 그래서 동시 생성 개수를 따로 제한하는 장치를 함께 두는 편이 안전하다.

```java
private final Semaphore exportPermits = new Semaphore(2);

public void exportWithLimit(YearMonth month, OutputStream out) throws IOException {
    if (!exportPermits.tryAcquire()) {
        throw new ResponseStatusException(HttpStatus.TOO_MANY_REQUESTS,
                "다른 엑셀 파일을 만드는 중입니다. 잠시 후 다시 시도해 주세요.");
    }
    try {
        exporter.export(month, out);
    } finally {
        exportPermits.release();
    }
}
```

이 제한은 인스턴스 하나 안에서만 동작한다. 여러 인스턴스 전체의 동시 생성 수를 맞춰야 하거나 대기열이 필요하다면, 그때는 비동기 생성 방식으로 넘어가는 것이 맞다.

## 정리

엑셀 다운로드 OOM을 다룰 때 확인할 순서를 체크리스트로 남긴다.

- OOM 메시지가 heap인지, metaspace인지, 스레드 생성 실패인지, direct buffer인지 먼저 구분했는가
- Java 로그 없이 프로세스가 사라졌다면 OS나 컨테이너의 종료 기록을 확인했는가
- `jcmd <pid> VM.flags`로 실제 적용된 `-Xmx`, `MaxMetaspaceSize`를 확인했는가
- 조회 결과를 전부 `List`로 받지 않고 한 행씩 읽어 바로 쓰는가
- XSSF 대신 SXSSF를 쓰고, `finally`에서 `dispose()`로 임시 파일을 지우는가
- 임시 디렉터리와 heap dump 경로에 디스크 여유가 있고, dump 파일의 접근 권한을 정했는가
- 동시 다운로드 수와 시트당 행 수 한도에 대한 정책이 있는가

heap 그래프는 프로세스 메모리 전체를 대신하지 않는다. 영역을 나눠 증거를 모으면 `-Xmx`를 올릴지, 코드를 바꿀지, 기능의 형태를 바꿀지를 근거를 가지고 정할 수 있다.

## 참고한 공식 문서

- [Oracle Java SE 21 `java` 명령 옵션](https://docs.oracle.com/en/java/javase/21/docs/specs/man/java.html)
- [Oracle Java SE 21 Troubleshooting Guide: Troubleshoot Memory Leaks](https://docs.oracle.com/en/java/javase/21/troubleshoot/troubleshooting-memory-leaks.html)
- [Oracle Java SE 21 `jcmd` 명령](https://docs.oracle.com/en/java/javase/21/docs/specs/man/jcmd.html)
- [Oracle Java SE 21 `jstat` 명령](https://docs.oracle.com/en/java/javase/21/docs/specs/man/jstat.html)
- [Apache POI Spreadsheet How-To: SXSSF (Streaming Usermodel API)](https://poi.apache.org/components/spreadsheet/how-to.html#sxssf)
