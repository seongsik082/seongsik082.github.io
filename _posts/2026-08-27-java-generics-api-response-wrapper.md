---
title: "사내 업무 API의 공통 응답 래퍼로 보는 Java 제네릭과 타입 소거"
date: 2026-08-27 08:56:00 +0900
tags: [Java, Generic, API, Backend]
excerpt: "공통 응답 래퍼와 PageResponse 예제로 제네릭 클래스·메서드, 타입 소거 때문에 필요한 TypeReference, PECS 와일드카드, 래퍼를 남용할 때의 비용을 정리한다."
redirect_from:
  - /posts/java-generics-member-profile-response/
---

사내 업무 시스템을 여러 팀이 나눠 만들다 보면 "모든 API 응답은 같은 모양으로 내보내자"는 규칙이 생긴다. 사원 목록, 부서 목록, 자산 대장처럼 목록을 돌려주는 API에는 페이지 정보까지 같은 구조로 맞추자는 요구가 따라온다. 이때 API마다 `EmployeeListResponse`, `DepartmentListResponse`를 복사해 만들거나, `Object data` 하나로 받아 꺼낼 때마다 형변환하는 대신 제네릭으로 `ApiResponse<T>`와 `PageResponse<T>`를 만든다. 그런데 제네릭은 컴파일 시점의 약속이라 런타임에는 `T`가 무엇이었는지 남지 않는다. 이 사실은 응답을 보내는 쪽보다 받는 쪽, 즉 다른 사내 시스템이나 테스트 코드가 JSON을 다시 객체로 읽을 때 드러난다. 이 글은 공통 응답 래퍼를 예로 제네릭 클래스와 메서드, 타입 소거와 그 결과, 와일드카드, raw type 경고, 그리고 래퍼를 남용할 때의 비용을 정리한다.

> 이 글의 예제는 개념을 설명하기 위해 구성한 코드이며, 특정 서비스의 운영 수치가 아니다.

## 응답은 잘 나가는데 받는 쪽에서 깨지는 장면

사원 목록 API `GET /api/employees?deptCode=D100&page=0&size=20`은 다음 JSON을 돌려준다.

```json
{
  "code": "OK",
  "message": "정상 처리되었습니다.",
  "data": {
    "content": [
      { "employeeNo": "E1001", "name": "김하늘", "deptCode": "D100" }
    ],
    "page": 0,
    "size": 20,
    "totalElements": 1,
    "totalPages": 1
  }
}
```

근태 정산 배치가 이 API를 호출해 부서별 인원을 세는 코드를 작성했다고 하자.

```java
ApiResponse<PageResponse<EmployeeSummary>> response =
        objectMapper.readValue(json, ApiResponse.class);   // unchecked 경고만 나고 컴파일된다

PageResponse<EmployeeSummary> page = response.data();      // 여기서 ClassCastException
```

```text
java.lang.ClassCastException: class java.util.LinkedHashMap cannot be cast to class com.example.common.api.PageResponse (java.util.LinkedHashMap is in module java.base of loader 'bootstrap'; com.example.common.api.PageResponse is in unnamed module of loader 'app')
```

`readValue`에 넘긴 것은 `ApiResponse.class` 하나뿐이다. Jackson은 `data`가 어떤 타입이어야 하는지 알 방법이 없으므로 JSON 객체를 `LinkedHashMap`으로 만든다. 그 객체는 아무 문제 없이 `response`에 대입된다. 오류는 `response.data()`의 결과를 `PageResponse` 변수에 담는 순간, 컴파일러가 보이지 않게 넣어 둔 형변환이 실행될 때 난다. 역직렬화한 줄이 아니라 한참 뒤에 값을 쓰는 줄에서 터지기 때문에 스택 트레이스만 보고는 원인을 짐작하기 어렵다. 이 장면을 이해하려면 제네릭이 어디까지 컴파일러의 일이고 어디부터 런타임의 일인지 나눠 봐야 한다.

## 제네릭 클래스와 제네릭 메서드로 래퍼를 만든다

```java
public record ApiResponse<T>(String code, String message, T data) {

    public static <T> ApiResponse<T> ok(T data) {
        return new ApiResponse<>("OK", "정상 처리되었습니다.", data);
    }
}

public record PageResponse<T>(List<T> content, int page, int size,
                              long totalElements, int totalPages) {

    public PageResponse {
        content = List.copyOf(content);
    }

    public static <T> PageResponse<T> of(List<? extends T> content, int page, int size,
                                         long totalElements) {
        int totalPages = size == 0 ? 0 : (int) ((totalElements + size - 1) / size);
        return new PageResponse<>(List.copyOf(content), page, size, totalElements, totalPages);
    }

    public <R> PageResponse<R> map(Function<? super T, ? extends R> mapper) {
        List<R> mapped = new ArrayList<>(content.size());
        for (T item : content) {
            mapped.add(mapper.apply(item));
        }
        return new PageResponse<>(mapped, page, size, totalElements, totalPages);
    }

    public void addContentTo(Collection<? super T> target) {
        target.addAll(content);
    }
}
```

클래스 선언의 `<T>`는 타입 매개변수다. `ApiResponse<EmployeeSummary>`라고 쓰는 순간 그 자리의 `T`가 `EmployeeSummary`로 정해지고, `data()`의 반환 타입도 함께 정해진다. `Object data`로 만들었다면 꺼낼 때마다 `(EmployeeSummary)`를 붙여야 하고, 잘못 붙인 형변환은 실행해 봐야 안다. 제네릭은 그 확인을 컴파일 시점으로 당겨 온다.

`static <T> ApiResponse<T> ok(T data)`의 `<T>`는 클래스의 `T`와 이름만 같은 별개의 타입 매개변수다. 정적 메서드는 특정 인스턴스에 속하지 않으므로 클래스의 `T`를 쓸 수 없고, 메서드 스스로 타입 매개변수를 선언해야 한다. `map`의 `<R>`처럼 인스턴스 메서드도 자기만의 타입 매개변수를 가질 수 있다. 저장소에서 꺼낸 행 객체를 응답 DTO로 바꾸는 변환이 이런 메서드의 대표적인 쓰임이다. 호출할 때 `<EmployeeSummary>`를 일일이 적지 않아도 되는 것은 컴파일러가 인자와 대입 대상을 보고 타입을 추론하기 때문이다.

compact constructor에서 `List.copyOf`로 복사해 두면 바깥에서 원래 리스트를 바꿔도 응답이 흔들리지 않는다. 다만 `List.copyOf`는 `null` 요소를 허용하지 않으므로, 조회 결과 행에 `null`이 섞일 수 없다는 전제가 함께 깔린다.

Controller에서는 다음처럼 쓴다.

```java
@RestController
@RequestMapping("/api/employees")
public class EmployeeQueryController {

    private final EmployeeQueryService employeeQueryService;

    public EmployeeQueryController(EmployeeQueryService employeeQueryService) {
        this.employeeQueryService = employeeQueryService;
    }

    @GetMapping
    public ApiResponse<PageResponse<EmployeeSummary>> search(
            @RequestParam("deptCode") String deptCode,
            @RequestParam(name = "page", defaultValue = "0") int page,
            @RequestParam(name = "size", defaultValue = "20") int size) {

        PageResponse<EmployeeRow> rows = employeeQueryService.search(deptCode, page, size);
        return ApiResponse.ok(rows.map(EmployeeSummary::from));
    }
}
```

## 타입 소거: 컴파일러가 확인하고 런타임에는 지운다

Java 튜토리얼은 타입 소거를 세 가지 일로 설명한다. 타입 매개변수를 경계 타입으로, 경계가 없으면 `Object`로 바꾼다. 타입 안전을 지키는 데 필요한 곳에 형변환을 넣는다. 상속 관계의 다형성을 유지하려고 필요하면 브리지 메서드를 만든다. 그래서 매개변수화된 타입마다 새 클래스가 생기지 않고, 제네릭 때문에 런타임 비용이 늘지도 않는다. 대신 런타임 객체는 자신이 어떤 `T`로 만들어졌는지 모른다.

```java
ApiResponse<String> notice = ApiResponse.ok("점검 공지");
ApiResponse<Integer> count = ApiResponse.ok(42);
System.out.println(notice.getClass() == count.getClass());   // true

// 아래는 모두 컴파일되지 않는다
// T value = new T();                    타입 변수로는 객체를 만들 수 없다
// Class<T> type = T.class;              타입 변수에는 클래스 리터럴이 없다
// if (obj instanceof PageResponse<EmployeeSummary> p) { }   Object 값을 이 타입으로 안전하게 검사할 수 없다
// void save(List<EmployeeSummary> rows) { }
// void save(List<DepartmentSummary> rows) { }               소거 후 시그니처가 같아 충돌한다
```

앞의 `ClassCastException`도 이 규칙으로 설명된다. 소거된 `data()`는 바이트코드에서 `Object`를 돌려주고, 호출한 쪽에 컴파일러가 `PageResponse`로의 형변환을 넣어 두었다. 런타임에는 그 형변환이 실행되는 시점에야 실제 값이 `LinkedHashMap`이라는 사실이 드러난다.

헷갈리기 쉬운 점이 하나 있다. 소거는 객체에서 타입 인자를 지우는 것이지, 선언에 적힌 제네릭 정보까지 지우는 것은 아니다. 필드 타입, 메서드의 반환 타입과 파라미터 타입, 상위 클래스 선언은 클래스 파일에 시그니처로 남고, 리플렉션의 `Method.getGenericReturnType()` 같은 API로 읽을 수 있다. Spring MVC가 Controller 메서드의 반환 타입이나 `@RequestBody` 파라미터의 제네릭 타입을 알아내는 것도 메서드 선언을 읽기 때문이다. 직렬화는 애초에 실제 객체를 보고 하니 문제가 없다. 깨지는 곳은 선언이 없는 곳, 즉 `ApiResponse.class` 같은 클래스 리터럴 하나만 넘기는 역직렬화다.

## 런타임에 타입을 넘기는 방법: TypeReference와 ParameterizedTypeReference

해법은 선언이 남는 성질을 이용한다. 익명 하위 클래스를 만들면 그 클래스의 상위 타입 선언에 `ApiResponse<PageResponse<EmployeeSummary>>`가 그대로 기록되고, 라이브러리는 이를 읽어 중첩된 타입까지 복원한다. Spring의 `ParameterizedTypeReference` Javadoc도 제네릭 타입을 런타임까지 붙잡아 두려면 하위 클래스, 가능하면 익명 내부 클래스를 만들어야 한다고 설명한다.

```java
// Jackson으로 직접 읽을 때
ApiResponse<PageResponse<EmployeeSummary>> response = objectMapper.readValue(json,
        new TypeReference<ApiResponse<PageResponse<EmployeeSummary>>>() {});
```

```java
// Spring RestClient로 다른 사내 시스템의 API를 호출할 때 (Spring Framework 6.1 이상)
@Component
public class EmployeeApiClient {

    private static final ParameterizedTypeReference<ApiResponse<PageResponse<EmployeeSummary>>>
            EMPLOYEE_PAGE = new ParameterizedTypeReference<>() {};

    private final RestClient restClient;

    public EmployeeApiClient(RestClient.Builder builder) {
        this.restClient = builder.baseUrl("https://hr.example.com").build();
    }

    public PageResponse<EmployeeSummary> fetch(String deptCode, int page, int size) {
        ApiResponse<PageResponse<EmployeeSummary>> body = restClient.get()
                .uri("/api/employees?deptCode={deptCode}&page={page}&size={size}",
                        deptCode, page, size)
                .retrieve()
                .body(EMPLOYEE_PAGE);
        return Objects.requireNonNull(body, "응답 본문이 비어 있다").data();
    }
}
```

끝의 `{}`가 핵심이다. 두 클래스 모두 추상 클래스라 `{}`를 빠뜨리면 컴파일되지 않고, 이 중괄호가 타입 정보를 담을 익명 하위 클래스를 만든다. 같은 타입을 여러 곳에서 쓴다면 위처럼 상수로 빼 두면 긴 타입 선언이 반복되지 않는다. 익명 클래스에 다이아몬드 `<>`를 쓰는 문법은 Java 9부터 쓸 수 있다.

`Class<T>`를 파라미터로 받는 방식과도 구분해야 한다. `<T> T read(String json, Class<T> type)`은 `EmployeeSummary`처럼 타입 인자가 없는 타입에는 충분하지만, `PageResponse<EmployeeSummary>`는 `Class` 객체로 표현할 수 없다. 중첩된 제네릭 타입을 다룰 일이 없는 유틸리티라면 `Class<T>`가 더 단순하고, 래퍼처럼 타입이 겹겹이 들어가는 곳이라면 타입 참조 객체가 필요하다.

## 와일드카드는 읽는지 쓰는지로 고른다

제네릭 타입은 무공변이다. `EmployeeSummary`가 `WorkerSummary`를 구현해도 `List<EmployeeSummary>`는 `List<WorkerSummary>`의 하위 타입이 아니다. 만약 그렇다면 사원 목록을 `List<WorkerSummary>`로 받은 메서드가 그 안에 외주 인력을 넣을 수 있게 되고, 원래 리스트를 쓰는 쪽은 사원이 아닌 객체를 꺼내게 된다. 와일드카드는 이 제약을 필요한 만큼만 푼다.

Java 튜토리얼의 지침은 다음과 같다. 값을 꺼내 읽기만 하는 "in" 변수는 `extends`로, 값을 넣기만 하는 "out" 변수는 `super`로 선언한다. 읽고 쓰기를 모두 한다면 와일드카드를 쓰지 않는다. 흔히 PECS(Producer Extends, Consumer Super)라고 부르는 규칙이다.

```java
public interface WorkerSummary {
    String name();
    String deptCode();
}

public record EmployeeSummary(String employeeNo, String name, String deptCode)
        implements WorkerSummary {

    public static EmployeeSummary from(EmployeeRow row) {
        return new EmployeeSummary(row.employeeNo(), row.name(), row.deptCode());
    }
}

public record ContractorSummary(String contractorId, String name, String deptCode,
                                LocalDate contractEndDate) implements WorkerSummary {
}

public final class WorkerStatistics {

    private WorkerStatistics() {
    }

    // 읽기만 한다(in): extends
    public static Map<String, Long> countByDept(Collection<? extends WorkerSummary> workers) {
        return workers.stream()
                .collect(Collectors.groupingBy(WorkerSummary::deptCode, Collectors.counting()));
    }
}

// 엑셀 내보내기용 행 목록에 두 종류의 페이지 결과를 모은다(out): super
List<WorkerSummary> exportRows = new ArrayList<>();
employeePage.addContentTo(exportRows);       // PageResponse<EmployeeSummary>
contractorPage.addContentTo(exportRows);     // PageResponse<ContractorSummary>
Map<String, Long> headcount = WorkerStatistics.countByDept(exportRows);
```

`countByDept`의 파라미터가 `Collection<WorkerSummary>`였다면 `List<EmployeeSummary>`를 넘길 때 컴파일 오류가 난다. `addContentTo`는 `PageResponse<T>`의 내용을 대상 컬렉션에 넣기만 하므로 `Collection<? super T>`를 받고, 덕분에 사원 페이지와 외주 인력 페이지를 하나의 `List<WorkerSummary>`에 모을 수 있다. 앞의 `map`이 `Function<? super T, ? extends R>`를 받는 것도 같은 규칙이다. 함수는 `T`를 소비하고 `R`을 생산하기 때문이다. `Stream.map`의 시그니처가 같은 모양인 것도 그래서다.

반대로 와일드카드를 쓰지 않는 편이 나은 곳도 분명하다. 튜토리얼은 반환 타입에 와일드카드를 쓰지 말라고 한다. `PageResponse<? extends WorkerSummary>`를 돌려주면 받는 쪽이 와일드카드를 계속 다뤄야 하기 때문이다. 같은 컬렉션을 읽고 쓰는 메서드, 그리고 한 가지 타입만 오가는 내부 메서드라면 구체 타입이 더 읽기 쉽다.

## raw type 경고를 꺼 두지 않는다

raw type은 제네릭 타입을 타입 인자 없이 쓴 것이다. `ApiResponse response`나 `List rows`처럼 쓰면 제네릭 도입 전의 동작으로 돌아가 타입 검사가 꺼지고, 안전하지 않은 코드가 런타임까지 숨는다. 첫 장면의 `objectMapper.readValue(json, ApiResponse.class)`도 raw `ApiResponse`를 돌려주었고, 컴파일러는 이를 매개변수화된 변수에 대입하는 지점에서 unchecked 경고를 냈다. 문제는 javac가 기본적으로 "unchecked or unsafe operations" 같은 요약 안내만 보여 준다는 점이다. 줄 단위 경고를 보려면 `-Xlint:unchecked`를 켜야 한다.

```groovy
// build.gradle
tasks.withType(JavaCompile).configureEach {
    options.compilerArgs += ['-Xlint:unchecked', '-Xlint:rawtypes']
}
```

```text
EmployeeSyncJob.java:42: warning: [unchecked] unchecked conversion
                objectMapper.readValue(json, ApiResponse.class);
                                      ^
  required: ApiResponse<PageResponse<EmployeeSummary>>
  found:    ApiResponse
```

경고를 없애려고 클래스 전체에 `@SuppressWarnings("unchecked")`를 붙이면 앞으로 생길 경고까지 함께 묻힌다. 런타임에 타입을 직접 확인했거나 구조상 안전함을 증명할 수 있을 때만, 그 지역 변수 선언처럼 가장 좁은 범위에 붙이고 왜 안전한지 주석을 남긴다. 경고를 빌드 실패로 바꾸는 `-Werror`는 새 프로젝트에는 효과적이지만, 경고가 많이 쌓인 기존 프로젝트에 한 번에 켜면 빌드가 멈춘다. 그런 프로젝트라면 경고를 먼저 보이게 하고, 새로 작성하는 코드부터 경고 없이 유지하는 편이 현실적이다.

## 공통 래퍼를 남용할 때의 비용

제네릭 래퍼가 편해지면 모든 응답을 감싸고, 실패까지 같은 모양에 넣고 싶어진다. 흔히 보이는 모양은 이렇다.

```http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "success": false,
  "code": "E404",
  "message": "사원을 찾을 수 없습니다.",
  "data": null
}
```

이 응답에는 몇 가지 비용이 있다. 첫째, `success`와 `code`는 HTTP 상태 코드가 이미 전하는 정보를 반복하고, 둘이 어긋나도 막을 장치가 없다. 실패를 200으로 보내면 접근 로그나 APM처럼 상태 코드로 오류율을 세는 도구가 모두 성공으로 집계한다. 둘째, Spring `RestClient`는 `retrieve()`로 받은 응답이 4xx·5xx이면 기본적으로 예외로 바꿔 주지만, 200이면 아무 일도 일어나지 않는다. 호출하는 쪽이 매번 `success`를 확인해야 하고, 확인을 빠뜨리면 `data`가 `null`인 채로 다음 로직이 진행된다. 셋째, 성공 응답도 한 단계씩 깊어진다. 래퍼에 페이지 정보나 경고 메시지처럼 실제로 의미 있는 값이 없다면 `response.data.content[0]`의 `data`는 깊이만 늘린 셈이다.

| 방식 | 장점 | 쓰지 않는 편이 나은 경우 |
| --- | --- | --- |
| 모든 응답을 `ApiResponse<T>`로 감싼다 | 클라이언트 파싱 코드가 하나로 모이고, 기존 사내 표준과 맞추기 쉽다 | 상태 코드를 200으로 고정하고 `success`로 실패를 표현하려 할 때 |
| 성공은 DTO 그대로, 실패는 ProblemDetail | HTTP 의미를 그대로 쓰고 RFC 9457 표준 형식과 맞는다 | 래퍼 형식에 맞춰 만든 클라이언트가 많아 한 번에 바꿀 수 없을 때 |
| 목록 API에만 `PageResponse<T>` | 페이지 정보가 실제로 필요한 곳에만 구조를 더한다 | "더 보기"처럼 전체 건수가 필요 없는 화면. 매 요청 COUNT 쿼리 비용만 생긴다 |

마지막 줄의 비용은 자주 간과된다. `totalElements`를 채우려면 목록 조회와 별도로 COUNT 쿼리가 실행되고, 조건이 복잡한 큰 테이블에서는 이 쿼리가 목록 조회만큼 무거울 수 있다. 전체 페이지 수가 필요 없는 화면이라면 `size + 1`건을 조회해 다음 페이지가 있는지만 알려 주는 방식으로 COUNT를 없앨 수 있다.

이미 래퍼 형식이 사내 표준으로 굳어 있다면 래퍼를 버리기보다, 상태 코드만큼은 실제 결과대로 내보내고 상태 코드에서 유도할 수 있는 `success` 같은 필드를 줄이는 것이 현실적인 절충이다. 오류 본문은 RFC 9457의 problem details처럼 `type`, `title`, `status`, `detail`을 갖춘 형식으로 맞추면 Spring의 `ProblemDetail`을 그대로 쓸 수 있다.

## 어떻게 확인하나

타입 소거의 결과를 직접 눈으로 보는 것이 가장 빠르다. 아래 테스트는 같은 JSON을 클래스 리터럴로 읽을 때와 `TypeReference`로 읽을 때를 비교한다.

```java
class ApiResponseJsonTest {

    private static final String JSON = """
            {"code":"OK","message":"정상 처리되었습니다.",
             "data":{"content":[{"employeeNo":"E1001","name":"김하늘","deptCode":"D100"}],
                     "page":0,"size":20,"totalElements":1,"totalPages":1}}
            """;

    private final ObjectMapper objectMapper = new ObjectMapper();

    @Test
    void 클래스_리터럴만_넘기면_data는_LinkedHashMap이_된다() throws Exception {
        ApiResponse<?> response = objectMapper.readValue(JSON, ApiResponse.class);

        assertThat(response.data()).isInstanceOf(LinkedHashMap.class);
    }

    @Test
    void TypeReference로_읽으면_중첩된_타입까지_복원된다() throws Exception {
        ApiResponse<PageResponse<EmployeeSummary>> response = objectMapper.readValue(JSON,
                new TypeReference<ApiResponse<PageResponse<EmployeeSummary>>>() {});

        EmployeeSummary first = response.data().content().get(0);
        assertThat(first.employeeNo()).isEqualTo("E1001");
        assertThat(response.data().totalPages()).isEqualTo(1);
    }
}
```

서버 쪽은 `curl -s "http://localhost:8080/api/employees?deptCode=D100&page=0&size=20"`로 호출해 `data.content`, `totalElements`, `totalPages`가 기대한 값인지 본다. 전체 건수가 21건이고 `size`가 20이라면 `totalPages`는 2여야 한다. 경계값인 0건, 20건, 21건을 `PageResponse.of`의 단위 테스트로 고정해 두면 페이지 계산 실수를 일찍 잡을 수 있다.

실패했을 때는 다음 순서로 본다.

- `LinkedHashMap cannot be cast to class ...` 메시지가 보이면 그 값을 역직렬화한 곳을 찾는다. `readValue(json, X.class)`, `convertValue(value, X.class)`, `body(X.class)`처럼 제네릭 타입에 클래스 리터럴을 넘긴 호출이 원인인 경우가 대부분이다.
- `-Xlint:unchecked`를 켜고 다시 컴파일해, 예외가 난 줄 근처에 unchecked conversion 경고가 있는지 확인한다.
- `TypeReference`로 바꿨는데도 역직렬화 단계에서 실패한다면 타입 문제가 아니라 생성 문제다. 레코드가 아닌 클래스라면 Jackson이 쓸 수 있는 생성자가 있는지 본다.
- 목록 API가 500으로 끝나고 로그에 `NullPointerException`과 `List.copyOf`가 보인다면 `map` 변환 함수가 어떤 행에서 `null`을 돌려준 것이다.
- `totalPages`가 기대보다 하나 많거나 적다면 `PageResponse.of`의 올림 계산과 `size`가 0일 때의 처리를 먼저 본다.

## 정리

- 구조는 같고 데이터 타입만 다른 클래스가 실제로 반복될 때 제네릭 클래스로 묶는다. 한 번만 쓰는 응답이라면 일반 DTO가 더 읽기 쉽다.
- 정적 팩토리 메서드는 클래스의 `T`를 쓸 수 없으므로 `static <T>`로 자기 타입 매개변수를 선언한다.
- 런타임 객체는 `T`를 모른다. 제네릭 타입을 역직렬화할 때는 `TypeReference`나 `ParameterizedTypeReference`로 타입을 넘긴다.
- 읽기만 하면 `? extends`, 넣기만 하면 `? super`, 둘 다 하거나 반환 타입이라면 와일드카드를 쓰지 않는다.
- `-Xlint:unchecked`로 raw type과 unchecked 경고를 보이게 하고, `@SuppressWarnings`는 가장 좁은 범위에만 이유와 함께 붙인다.
- 래퍼를 쓰더라도 HTTP 상태 코드는 실제 결과대로 내보내고, 페이지 정보는 정말 필요한 목록 API에만 붙인다.

## 참고한 공식 문서

- [Type Erasure (The Java Tutorials)](https://docs.oracle.com/javase/tutorial/java/generics/erasure.html)
- [Guidelines for Wildcard Use (The Java Tutorials)](https://docs.oracle.com/javase/tutorial/java/generics/wildcardGuidelines.html)
- [Raw Types (The Java Tutorials)](https://docs.oracle.com/javase/tutorial/java/generics/rawTypes.html)
- [ParameterizedTypeReference (Spring Framework API)](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/core/ParameterizedTypeReference.html)
- [RFC 9457: Problem Details for HTTP APIs](https://www.rfc-editor.org/rfc/rfc9457.html)
