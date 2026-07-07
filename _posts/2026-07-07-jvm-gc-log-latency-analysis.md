---
title: "JVM GC 로그를 켜지 않으면 p99 지연 원인을 추측으로만 보게 되는 이유"
date: 2026-07-07 08:56:00 +0900
tags: [Java, Performance, Backend]
excerpt: "JVM GC 로그는 메모리 튜닝용 옵션만이 아니라 p95, p99 지연이 튈 때 애플리케이션 코드 문제와 런타임 pause를 구분하게 해주는 운영 증거입니다."
---

API 응답 시간이 평소 80ms인데 가끔 p99가 2초까지 튄다고 해보자. DB slow query는 보이지 않고, 외부 API timeout도 없다. 애플리케이션 로그에는 요청 시작과 종료 사이가 비어 있다. 이때 GC 로그가 없으면 "GC 때문인 것 같다"와 "아닌 것 같다" 사이에서 추측만 하게 된다.

Garbage Collection, 줄여서 GC는 JVM이 더 이상 쓰지 않는 객체 메모리를 회수하는 작업이다. 대부분의 시간에는 개발자가 신경 쓰지 않아도 된다. 문제는 GC가 애플리케이션 스레드를 멈추는 pause를 만들 수 있고, 그 pause가 사용자의 요청 지연으로 보일 수 있다는 점이다.

GC 로그는 성능 튜닝 전문가만 보는 자료가 아니다. 운영에서는 "이 시간대 p99 지연이 JVM pause와 겹쳤는가", "heap이 계속 차오르는가", "컨테이너 메모리 제한에 비해 heap을 과하게 잡았는가"를 확인하는 기본 증거다. 로그를 켜지 않은 상태에서 장애가 나면 이미 늦다.

## 문제 상황

다음과 같은 현상이 같이 나타나면 GC 확인이 필요하다.

- 특정 endpoint가 아니라 전체 API p99가 동시에 튄다.
- CPU 사용률은 높지 않은데 요청 처리 시간이 늘어난다.
- DB, Redis, 외부 API 지표에는 같은 시간대 병목이 없다.
- 컨테이너가 간헐적으로 OOMKilled 되거나 RSS가 계속 오른다.

이때 애플리케이션 로그만 보면 원인 구분이 어렵다. 요청 스레드가 실제로 코드를 실행하다 느려진 것인지, JVM이 잠깐 멈췄는지, OS나 컨테이너 메모리 압박이 있었는지 분리해야 한다. GC 로그는 이 분리의 출발점이다.

예를 들어 09:12:03에 p99가 튀었고 같은 시각 GC 로그에 1.8초 pause가 찍혔다면 조사 방향이 바뀐다. 쿼리 최적화보다 allocation 증가, heap 크기, collector 선택, object lifetime을 먼저 봐야 한다.

## 핵심 개념

GC를 볼 때 처음부터 collector 내부 알고리즘을 외울 필요는 없다. 운영에서 먼저 볼 것은 세 가지다.

첫째, pause time이다. GC 때문에 애플리케이션 스레드가 멈춘 시간이다. 짧은 pause가 자주 생기는 것과 긴 pause가 가끔 생기는 것은 사용자 경험이 다르다. p99 지연 문제에서는 긴 pause가 tail latency를 직접 밀어 올릴 수 있다.

둘째, heap occupancy다. GC 전후 heap이 얼마나 차 있고 얼마나 회수되는지 보는 값이다. GC 뒤에도 사용량이 계속 높게 남으면 live object가 많거나 memory leak 가능성이 있다. 반대로 회수는 잘 되지만 너무 자주 GC가 돈다면 allocation rate가 높을 수 있다.

셋째, container memory와 heap의 관계다. JVM heap만 메모리를 쓰는 것이 아니다. metaspace, thread stack, direct buffer, code cache, native memory도 있다. `-Xmx`를 컨테이너 limit에 너무 가깝게 잡으면 heap 바깥 메모리 때문에 OOM이 날 수 있다.

Oracle Java 21 문서 기준으로 `-XX:MaxRAMPercentage`는 JVM이 사용할 최대 heap 비율을 조정하는 옵션이다. 기본값만 믿기보다 컨테이너 limit, thread 수, off-heap 사용 여부를 함께 고려해야 한다.

## 설정으로 보기

Java 9 이후에는 unified logging 기반으로 GC 로그를 설정할 수 있다. 운영에서 시작점으로는 시간, tag, level, 파일 회전이 있는 형태가 다루기 쉽다.

```bash
java \
  -Xlog:gc*,safepoint:file=/var/log/app/gc.log:time,uptime,level,tags:filecount=5,filesize=20M \
  -XX:MaxRAMPercentage=70 \
  -jar app.jar
```

이 설정은 GC와 safepoint 관련 로그를 파일로 남기고, 파일 크기와 개수를 제한한다. `safepoint`는 JVM이 특정 작업을 위해 스레드들을 안전한 지점에 모으는 순간이다. GC pause와 같이 애플리케이션이 멈춘 시간을 이해할 때 같이 보면 도움이 된다.

컨테이너 환경에서는 로그 파일 경로도 운영 방식에 맞춰야 한다. 파일로 남길지, stdout으로 보낼지, sidecar나 agent가 수집할지 정한다. 중요한 것은 장애가 난 뒤에야 옵션을 켜는 것이 아니라 평소에도 낮은 비용으로 수집 가능한 수준을 유지하는 것이다.

## 로그를 읽는 순서

처음부터 모든 줄을 해석하려고 하면 어렵다. p99 지연 분석에서는 다음 순서로 보면 된다.

1. 지연이 튄 시각과 GC pause 시각이 겹치는지 본다.
2. pause duration이 SLO에 영향을 줄 만큼 긴지 본다.
3. GC 전후 heap 사용량이 회수되는지 본다.
4. 같은 패턴이 배포, 트래픽 증가, 특정 배치 작업과 겹치는지 본다.
5. 컨테이너 memory limit과 heap 설정이 너무 붙어 있는지 본다.

예시는 단순화하면 이런 식이다.

```text
[2026-07-07T09:12:03.120+0900][info][gc] GC(42) Pause Young ... 512M->180M(1024M) 85.321ms
[2026-07-07T09:12:10.441+0900][info][gc] GC(43) Pause Full ... 980M->940M(1024M) 1840.112ms
```

첫 줄은 young GC가 85ms 걸렸고 heap 사용량이 크게 줄었다. 두 번째 줄은 full GC가 1.8초 걸렸는데 회수량이 작다. p99 지연이 두 번째 줄과 겹친다면, 단순한 순간 부하보다 live object 증가나 heap 압박을 의심할 수 있다.

## 자주 하는 실수

첫 번째 실수는 평균 응답 시간만 보는 것이다. GC pause는 모든 요청을 균등하게 느리게 만들기보다 특정 순간에 걸린 요청을 크게 늦춘다. 그래서 평균은 멀쩡한데 p95, p99만 튈 수 있다.

두 번째 실수는 `-Xmx`를 컨테이너 limit와 거의 같게 잡는 것이다. JVM은 heap 밖에서도 메모리를 쓴다. direct buffer를 쓰는 Netty, 많은 thread, 큰 metaspace, profiling agent가 있으면 heap 바깥 사용량이 무시할 수 없어진다.

세 번째 실수는 GC 로그를 너무 자세히 켜서 운영 로그 비용을 키우거나, 반대로 아예 꺼서 사고 때 근거를 잃는 것이다. 일반 운영에서는 핵심 tag와 파일 회전으로 시작하고, 깊은 분석이 필요할 때만 더 자세한 로깅이나 JFR 같은 도구를 추가하는 편이 낫다.

네 번째 실수는 collector 변경부터 하는 것이다. G1, ZGC, Shenandoah 같은 collector 선택은 중요하지만, allocation 폭증이나 큰 객체 생성 패턴이 원인이라면 collector만 바꿔도 근본 문제가 남는다. 먼저 로그로 현상을 확인해야 한다.

## 언제 무엇을 조정할까

짧은 GC가 너무 자주 돈다면 allocation rate를 본다. 요청마다 큰 JSON 문자열을 여러 번 만들거나, 불필요한 collection 복사가 많은지 프로파일링한다. 캐시가 객체를 과하게 붙잡고 있는지도 확인한다.

긴 full GC가 보이고 회수량이 작다면 live object가 계속 남는지 본다. 메모리 leak, 무제한 Map, 큰 in-memory queue, 만료되지 않는 local cache가 후보가 된다. 이 경우 heap dump와 객체 참조 분석이 필요할 수 있다.

컨테이너 OOM이 보이면 heap만 줄이는 것으로 끝내지 않는다. thread 수, direct memory, native library, agent 사용량도 본다. `MaxRAMPercentage`를 낮추고도 OOM이 난다면 JVM 외부 메모리 관측을 같이 해야 한다.

실무 기준은 명확하다. p99 지연 시각과 긴 pause가 반복해서 겹치면 GC를 성능 원인 후보로 올린다. 겹치지 않으면 DB, 외부 API, lock, thread pool, 네트워크 쪽으로 조사 범위를 옮긴다. GC 로그는 답을 바로 주기보다 원인 후보를 빠르게 줄여준다.

## 운영에서 볼 것

GC를 운영 지표로 볼 때는 로그와 메트릭을 함께 둔다.

- GC pause duration의 p95, p99, max
- GC frequency와 단위 시간당 GC 횟수
- GC 전후 heap 사용량 추세
- old generation 사용량 증가 추세
- container memory usage와 OOMKilled 이벤트
- 배포, 트래픽 피크, 배치 작업과의 시간 상관관계

알림은 단순히 GC가 발생했다는 이유로 울리면 안 된다. GC는 정상 동작이다. "pause가 SLO 예산을 침범했다", "full GC가 반복되고 회수량이 작다", "컨테이너 메모리 limit에 지속적으로 가까워진다"처럼 사용자 영향이나 위험 신호와 연결해야 한다.

## 정리

JVM GC 로그는 튜닝 취미가 아니라 p99 지연과 런타임 pause를 연결하는 운영 증거다. 평소에 낮은 비용으로 GC와 safepoint 로그를 남기고, 지연 시각과 pause를 맞춰보며, heap과 컨테이너 메모리를 함께 봐야 한다. 추측으로 collector를 바꾸기 전에 로그로 어떤 종류의 pause가 실제로 있었는지 확인하자.

참고한 공식 문서:

- [Oracle Java 21 - The java Command](https://docs.oracle.com/en/java/javase/21/docs/specs/man/java.html)
- [Oracle Java 21 - Tools Reference](https://docs.oracle.com/en/java/javase/21/docs/specs/man/)
