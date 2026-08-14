---
title: "JVM 메모리 영역을 모르면 Spring 서비스의 OOM을 Heap만 보고 오진하는 이유"
date: 2026-08-14 22:55:00 +0900
tags: [Java, JVM, Spring Boot, Operations, Backend]
excerpt: "Spring 서비스의 메모리 문제를 heap, thread stack, metaspace, direct buffer로 나눠 관찰해야 하는 이유를 정리합니다. JVM MXBean으로 각 영역을 기록하고, OOM과 응답 지연에서 무엇부터 확인할지 실무 순서로 설명합니다."
---

# JVM 메모리 영역을 모르면 Spring 서비스의 OOM을 Heap만 보고 오진하는 이유

> **부제:** heap 사용률이 낮아도 컨테이너가 죽을 수 있다. Java 프로세스가 쓰는 메모리를 영역별 책임으로 나누어 읽는 법

**대상 독자:** Spring Boot로 CRUD API를 만들어 봤고, 운영 환경의 `OutOfMemoryError`나 컨테이너 OOMKilled 로그를 처음 마주한 주니어 백엔드 개발자

상품 조회 API가 갑자기 종료됐다는 알림을 받으면 보통 가장 먼저 “heap이 꽉 찼나?”를 떠올린다. 그 판단은 절반만 맞다. Java 프로세스는 객체와 배열을 담는 heap 외에도 요청을 처리하는 스레드의 stack, 클래스 정보를 담는 metaspace, 네트워크 I/O에 자주 쓰이는 direct buffer 등 여러 곳에서 메모리를 사용한다.

그래서 heap 사용률이 55%인데 Kubernetes Pod가 OOMKilled 될 수도 있다. `-Xmx`만 바꾸면 원인을 설명하지 못할 수 있다. 목표는 **어느 영역을 어떤 순서로 확인할지** 판단하는 것이다.

## 1. 오늘의 주제

온라인 쇼핑몰의 상품 목록 API를 생각해 보자. 대량 상품 등록 배치가 실행되는 시간에 컨테이너가 재시작됐는데, 종료 직전 heap 사용률 그래프는 limit에 닿지 않았다.

여기서 해야 할 일은 “메모리가 부족하다”를 “어느 종류의 메모리가 증가했나”로 바꾸는 것이다. 요청 DTO, JPA 조회 결과, `List`, 캐시 객체는 heap에 들어간다. 하지만 요청 처리 스레드가 너무 많이 늘어나면 각 stack도 프로세스 메모리를 사용하고, HTTP 클라이언트의 direct buffer 증가는 heap 그래프에 그대로 나타나지 않는다.

첫 판단 기준은 간단하다. **컨테이너 메모리와 heap 사용량의 차이가 계속 커지면, heap dump 전에 thread 수·metaspace·direct buffer를 함께 기록한다.** 반대로 heap이 상한에 가깝고 GC 뒤에도 내려오지 않으면 객체 생명주기와 heap dump 분석이 우선이다.

## 2. 핵심 개념

JVM은 실행 중인 Java 프로그램의 메모리를 하나의 숫자로만 관리하지 않는다. 이름을 외우기보다 “어떤 코드 변화가 이 영역을 키우는가”를 연결해 두는 편이 유용하다.

**heap**은 객체와 배열이 할당되는 런타임 영역이다. `new ProductResponse(...)`, `ArrayList`, JSON 역직렬화 결과, 로컬 캐시가 대표적이다. GC 뒤에도 사용량이 높다면 살아 있는 객체가 많거나 의도치 않은 참조가 남은 것이다. heap 문제는 GC 로그, heap 사용량, heap dump가 증거가 된다.

**metaspace**는 로드된 클래스의 메타데이터와 관련된 non-heap 영역이다. Spring 애플리케이션은 기동 시 많은 클래스를 로드한다. metaspace가 계속 커진다면 “Spring이라서 원래 그렇다”고 넘기지 말고 동적 프록시나 해제되지 않는 class loader처럼 클래스 수가 계속 증가하는 경로를 확인한다.

**thread stack**은 각 Java 스레드가 호출 정보와 지역 변수를 유지하는 공간이다. `-Xss`는 스레드 하나의 stack 크기와 관련된다. 무제한 요청 처리 스레드나 요청마다 만드는 executor는 heap과 무관하게 메모리를 압박한다. stack을 줄이기보다 스레드 수와 큐·거절 정책을 먼저 바로잡는다.

**direct buffer**는 `ByteBuffer.allocateDirect`처럼 heap 밖 메모리를 사용하는 버퍼다. `BufferPoolMXBean`은 direct 또는 mapped buffer pool의 사용량 추정치를 제공한다. 네트워크 I/O 서비스에서 heap은 안정적인데 컨테이너 메모리만 늘어난다면 이 값을 같이 본다. 단, 값 하나만으로 라이브러리 버그를 확정해서는 안 된다.

## 3. 내부 동작 원리

상품 검색 요청 하나가 들어온 순간을 따라가 보자. Tomcat worker thread가 요청을 받으면 그 호출 경로의 지역 변수와 메서드 프레임은 해당 thread stack에 쌓인다. Controller가 만든 요청 객체, Service가 조립한 DTO, Repository가 반환한 엔티티와 컬렉션은 heap에 놓인다. JSON 응답을 만들거나 외부 재고 API에 연결할 때는 라이브러리에 따라 heap 객체와 별도로 direct buffer가 사용될 수 있다.

요청이 끝나면 지역 변수 자체가 즉시 메모리를 비우는 것은 아니다. 참조가 끊긴 heap 객체는 이후 GC가 회수할 수 있는 후보가 된다. 반면 static `Map`이나 만료 없는 로컬 캐시에 DTO를 넣어 두면 요청은 끝나도 참조가 남는다. 이것이 heap retention, 즉 객체가 필요 이상으로 살아남는 전형적인 경로다. GC가 자주 실행되는 것과 누수가 있다는 것은 같은 말이 아니다. GC 이후 heap 점유량이 어떻게 변하는지를 함께 봐야 한다.

컨테이너 관점에서는 JVM이 예약한 메모리와 실제 사용량도 구분해야 한다. `-Xmx`는 Java heap의 최대 크기와 관련된 옵션이지 프로세스 전체의 상한이 아니다. `-XX:MaxRAMPercentage`도 최대 heap을 산정할 비율을 정할 뿐이다. Pod limit 전체를 heap에 배정하면 heap 밖 영역의 여지가 줄어든다.

관측 순서는 다음 다섯 단계로 두면 막연한 튜닝을 줄일 수 있다.

1. Pod 또는 프로세스의 전체 메모리 추세와 OOMKilled 여부를 먼저 확인한다.
2. 같은 시간대 heap 사용량과 GC 뒤 사용량을 본다.
3. thread count가 증가했는지, 특정 executor의 active thread와 queue가 쌓였는지 확인한다.
4. metaspace와 direct buffer 사용량을 영역별로 비교한다.
5. 차이가 계속 남을 때만 NMT, heap dump, thread dump처럼 비용이 더 큰 진단 자료를 수집한다.

이 순서는 “항상 heap dump부터”보다 안전하다. heap dump는 크고 민감한 데이터를 포함할 수 있고 heap 밖 원인에는 직접 답하지 못한다. NMT는 JVM 내부 native allocation을 분류할 수 있지만 JNI가 JVM 밖에서 직접 할당한 메모리까지 모두 추적하지는 않는다.

## 4. 실제 코드

아래 코드는 Spring Boot 애플리케이션에서 heap, non-heap, thread 수, direct buffer를 한 번에 로그로 남기는 최소 예시다. 특정 메모리 pool 이름을 하드코딩하지 않고 `MemoryPoolMXBean` 목록을 순회한다. GC 종류와 JDK에 따라 pool 이름이 다를 수 있기 때문이다. 이 코드는 메모리 부족을 자동 복구하는 장치가 아니라, 장애 조사에서 “무엇이 늘었는지”를 남기는 관측 코드다.

```java
package com.example.catalog.ops;

import java.lang.management.BufferPoolMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryPoolMXBean;
import java.lang.management.MemoryUsage;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
public class JvmMemoryReporter {
    private static final Logger log = LoggerFactory.getLogger(JvmMemoryReporter.class);

    @Scheduled(fixedDelayString = "${ops.jvm-memory-report-ms:60000}")
    public void report() {
        var memory = ManagementFactory.getMemoryMXBean();
        MemoryUsage heap = memory.getHeapMemoryUsage();
        MemoryUsage nonHeap = memory.getNonHeapMemoryUsage();
        int threads = ManagementFactory.getThreadMXBean().getThreadCount();

        long directBytes = ManagementFactory
                .getPlatformMXBeans(BufferPoolMXBean.class)
                .stream()
                .filter(pool -> "direct".equals(pool.getName()))
                .mapToLong(BufferPoolMXBean::getMemoryUsed)
                .filter(bytes -> bytes >= 0)
                .sum();

        log.info("jvm_memory heap_used={} heap_max={} jvm_non_heap_used={} threads={} direct_used={}",
                heap.getUsed(), heap.getMax(), nonHeap.getUsed(), threads, directBytes);

        List<MemoryPoolMXBean> pools = ManagementFactory.getMemoryPoolMXBeans();
        pools.forEach(pool -> {
            MemoryUsage usage = pool.getUsage();
            if (usage != null) {
                log.debug("jvm_memory_pool name={} type={} used={} max={}",
                        pool.getName(), pool.getType(), usage.getUsed(), usage.getMax());
            }
        });
    }
}
```

이 코드를 사용하려면 애플리케이션 설정에서 scheduling을 켜야 한다. 이미 다른 스케줄러가 있다면 중복 설정하지 말고, 공통 설정 위치에만 둔다.

```java
@SpringBootApplication
@EnableScheduling
public class CatalogApplication {
    public static void main(String[] args) {
        SpringApplication.run(CatalogApplication.class, args);
    }
}
```

개발 환경에서는 상품 목록을 반복 호출하고 로그 변화를 먼저 확인한다. 요청 수만 늘렸는데 `threads`가 계속 증가하면 executor 설정을 먼저 본다. 대량 JSON 응답에서 `heap_used`가 GC 뒤 내려오지 않을 때만 컬렉션·캐시·비동기 작업의 참조를 코드에서 추적한다.

운영에서는 핵심 값은 메트릭으로 보내고 pool별 상세 로그는 debug 또는 장애 재현 기간에 한정한다. Java 공식 문서도 MXBean 관측을 저메모리 상태에서 애플리케이션이 스스로 복구하는 장치로 쓰도록 의도한 것은 아니라고 설명한다.

## 5. 실제 서비스 적용

상품·재고·리뷰를 묶어 반환하는 API라면 메모리 관측을 요청 경로와 함께 설계한다. 한 페이지에 20개만 응답하는데 Service에서 모든 상품을 조회한 뒤 Java stream으로 자르면 DB 결과와 DTO가 heap에 불필요하게 만들어진다. heap을 늘리기 전에 pagination을 Repository 쿼리까지 전달하고 응답 최대 건수를 고정한다.

두 번째 산출물은 실행 설정이다. Kubernetes에서 `limits.memory: 1Gi`인 Pod에 `-Xmx`를 1Gi로 두지 않는다. thread 수, HTTP 클라이언트, 파일 처리, agent 여부를 고려해 heap 밖 여유를 남긴다. 정확한 비율은 서비스마다 다르므로 staging의 실제 트래픽 형태로 관측한 뒤 조정한다.

```yaml
resources:
  requests:
    memory: "768Mi"
  limits:
    memory: "1Gi"
env:
  - name: JAVA_TOOL_OPTIONS
    value: "-XX:MaxRAMPercentage=65 -Xlog:gc*:stdout:time,level,tags"
```

위 값은 복사해서 정답으로 쓰는 설정이 아니다. `MaxRAMPercentage=65`는 heap 밖 메모리를 위한 여유를 의도적으로 남긴 예시다. 배포 전 검증 절차는 다음처럼 짧고 반복 가능하게 만든다. 첫째, 실제 Pod limit와 JVM 옵션을 배포 manifest에서 확인한다. 둘째, 상품 조회·대량 등록·외부 재고 API 호출처럼 메모리 모양이 다른 세 요청을 staging에서 실행한다. 셋째, 컨테이너 메모리·heap·thread·direct buffer를 같은 시간 축으로 저장한다. 넷째, 트래픽이 끝난 뒤 사용량이 안정화되는지 본다.

Pod가 OOMKilled 됐는데 heap이 낮다면 `kubectl describe pod`의 종료 사유와 컨테이너 메모리 그래프부터 보고, `jvm_memory` 로그의 thread·direct 값을 비교한다. heap이 상한에 가까울 때만 GC 로그의 회수 전후 사용량을 보고 heap dump를 검토한다. “재시작했더니 정상”은 해결이 아니라 관찰 창이 사라졌다는 뜻일 수 있다.

## 6. 흔히 발생하는 문제

첫 번째 문제는 `OutOfMemoryError: Java heap space`와 컨테이너 OOMKilled를 같은 오류라고 보는 것이다. 전자는 JVM heap 할당 실패이고, OOMKilled는 컨테이너 한도를 넘어 플랫폼이 프로세스를 종료한 결과다. 후자만 보인다면 heap 밖 메모리도 조사 대상이다.

두 번째는 `-Xmx`를 올려서 배포를 통과시키는 것이다. heap 객체가 과도하게 쌓일 때 임시 완화는 될 수 있지만, 같은 limit에서 heap만 키우면 native 영역 공간은 줄어든다. 대량 응답, 무제한 local cache, pagination 누락이 남아 있다면 다음 피크에서 다시 실패한다.

세 번째는 스레드 수를 CPU 사용률과 분리해서 보지 않는 것이다. 외부 재고 API가 느려졌을 때 요청마다 새 thread를 만들거나 executor의 최대 수를 크게 올리면, 기다리는 작업이 많아진다. 각 스레드의 stack과 scheduler 비용이 늘고, 결국 메모리 압박과 응답 지연이 함께 커진다. 먼저 외부 호출의 connect/read timeout, bounded queue, 거절 시 동작을 정한 뒤 필요한 동시성만 허용한다. 이전 글에서 다룬 무한 큐와 `maxPoolSize`의 관계도 이 판단과 이어진다.

네 번째는 NMT를 만능 메모리 추적기로 오해하는 것이다. NMT는 JVM 내부 native allocation을 요약하거나 비교하는 데 유용하다. 하지만 JNI 코드처럼 JVM 밖에서 직접 할당한 native 메모리를 모두 추적하지는 않으며, Oracle 문서는 NMT 활성화에 성능 저하와 자체 메모리 비용이 있을 수 있다고 안내한다. 따라서 상시 상세 모드보다는 재현 환경에서 baseline을 잡고 `summary.diff`를 비교하는 방식이 낫다.

```bash
# NMT는 JVM 시작 시 활성화해야 한다.
java -XX:NativeMemoryTracking=summary -jar catalog-api.jar

# 같은 JVM 안에서 기준점과 이후 차이를 비교한다.
jcmd <pid> VM.native_memory baseline
jcmd <pid> VM.native_memory summary.diff
```

다섯 번째는 메모리 수집 코드가 서비스를 방해하게 만드는 것이다. 매 요청마다 MXBean을 순회해 `info` 로그를 남기면 로그량과 CPU 비용이 늘어난다. 일정 주기의 가벼운 메트릭으로 시작하고, 상세 로그는 debug 레벨로 제한한다.

## 7. 기술 선택의 Trade-off

메모리 설정은 “큰 heap이 좋다”와 “작은 heap이 좋다” 중 하나를 고르는 문제가 아니다. 응답 지연, 객체 생성량, 컨테이너 여유, 스레드 모델, 운영에서 확보할 수 있는 증거를 함께 고르는 문제다. 아래 순서로 결정하면 주니어 개발자도 설정값을 이유와 함께 제안할 수 있다.

1. 먼저 Pod의 메모리 limit와 실제 최대 동시 요청 수를 확인한다. limit를 모른 채 `-Xmx`만 논의하지 않는다.
2. heap·GC 로그로 객체 retention인지 일시적 allocation인지 구분한다. retention 증거가 없으면 heap dump를 기본 절차로 삼지 않는다.
3. thread 수와 executor queue를 확인한다. I/O 대기가 원인이라면 스레드 증가보다 timeout·큐·거절 정책이 우선이다.
4. direct buffer와 metaspace를 기록해 heap 밖의 추세를 확인한다. 값이 증가한다고 즉시 라이브러리를 교체하지 말고, 어떤 요청·배치·배포와 함께 증가하는지 연결한다.
5. 그 뒤에야 `MaxRAMPercentage`, `-Xmx`, pool 크기, 캐시 크기를 staging 부하 검증 결과와 함께 조정한다.

큰 heap은 GC 빈도를 낮출 수 있지만 heap 밖 공간을 잠식할 수 있다. 작은 heap은 안전 여유를 만들지만 allocation이 많은 서비스에서는 GC를 더 자주 유발할 수 있다. 작은 서비스에는 collector 교체보다 페이지 크기 제한·bounded executor·핵심 메트릭이 더 큰 효과를 낼 때가 많다.

반대로 이 접근을 적용하지 않는 조건도 분명하다. 단발성 CLI 배치처럼 짧게 실행되고 메모리 한도와 입력 크기가 엄격히 고정된 프로그램이라면, Spring 안에 주기적 메모리 reporter를 넣는 운영 복잡도는 과할 수 있다. 그 경우 실행 전 입력 크기 검증, JVM 옵션, 종료 코드와 GC 로그만으로도 충분한지 먼저 판단한다. 서비스 성격에 맞지 않는 관측을 늘리는 것은 안정성을 높이지 않는다.

정리하면, heap 그래프는 전체 프로세스 메모리의 대체물이 아니다. 메모리 장애에서는 전체 limit에서 시작해 heap, thread, non-heap, direct buffer를 차례로 분리한다. 시간 흐름과 요청·배치·배포의 관계를 남겨야 다음 설정 변경이 검증이 된다.

### 참고한 공식 문서

- [Oracle Java 21 MemoryMXBean](https://docs.oracle.com/en/java/javase/21/docs/api/java.management/java/lang/management/MemoryMXBean.html): heap과 non-heap, memory pool 관측의 의미를 확인했다.
- [Oracle Java 21 BufferPoolMXBean](https://docs.oracle.com/en/java/javase/21/docs/api/java.management/java/lang/management/BufferPoolMXBean.html): direct·mapped buffer pool의 사용량 추정치와 한계를 확인했다.
- [Oracle Java 21 java 명령 옵션](https://docs.oracle.com/en/java/javase/21/docs/specs/man/java.html): `-Xmx`, `-Xss`, `MaxRAMPercentage`의 적용 범위를 확인했다.
- [Oracle Java 21 메모리 누수 진단](https://docs.oracle.com/en/java/javase/21/troubleshoot/troubleshooting-memory-leaks.html): NMT의 활성화 방법, `jcmd` 비교 방식, 추적 범위와 비용을 확인했다.
