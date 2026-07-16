---
title: "Redis TTL만 맞추면 cache stampede를 막을 수 없는 이유"
date: 2026-07-16 08:51:00 +0900
tags: [Redis, Distributed Systems, Performance, Backend]
excerpt: "인기 키가 같은 시각에 만료되면 여러 애플리케이션 인스턴스가 동시에 원본 DB를 조회해 cache stampede를 만들 수 있습니다. TTL jitter, key별 single-flight, stale 허용, 원본 보호를 함께 적용할 때의 선택 기준과 지표를 정리합니다."
---

## 문제 상황

Redis를 붙인 뒤 평소에는 DB 부하가 낮은데 특정 시각마다 DB CPU와 connection pool 대기가 튀는 장애가 있습니다. 인기 키 수천 개의 TTL이 거의 같은 시각에 끝나 모든 인스턴스가 원본 DB를 조회하는 cache stampede일 수 있습니다. TTL은 오래된 값을 없애지만 만료 순간의 동시 실행을 조정하지 않으므로, 긴 TTL로 바꿔도 문제 시점만 늦어집니다.

## cache-aside와 stampede의 차이

Cache-aside는 애플리케이션이 Redis를 먼저 조회하고, miss이면 원본 DB 결과를 Redis에 저장하는 패턴입니다. TTL은 stale 데이터의 최대 시간을 제한합니다.

문제는 인기 키 하나가 만료되는 순간입니다. 100개의 애플리케이션 요청이 거의 동시에 miss를 보면, 100개가 같은 SELECT를 실행할 수 있습니다. 원본 DB는 캐시가 없을 때의 요청을 처리하도록 설계되지 않았기 때문에 connection pool 대기, lock 경합, p99 증가가 연쇄적으로 나타납니다. Redis 공식 문서도 인기 키의 동시 만료가 여러 프로세스의 중복 원본 조회를 만드는 상황을 cache stampede로 설명합니다.

## 첫 번째 방어선: TTL을 정렬하지 않는다

각 키에 같은 TTL을 주지 않고 작은 무작위 값을 더하거나 빼면 만료가 여러 시각으로 분산됩니다.

    base_ttl = 300
    jitter = random_between(-30, 30)
    redis.set(cache_key, payload, ex=base_ttl + jitter)

TTL jitter는 구현이 단순하고 전체 캐시의 만료 폭발을 완화하는 데 효과적입니다. 다만 인기 키 하나가 수동 삭제되거나 원본 변경 이벤트로 무효화되는 상황에는 도움이 되지 않습니다. 또한 같은 hot key를 여러 요청이 동시에 처음 채우는 cold start 문제도 해결하지 못합니다. 따라서 jitter는 기본 방어선이지 단독 해결책이 아닙니다.

## 두 번째 방어선: key별 single-flight

같은 키를 채우는 요청 중 하나만 원본을 조회하게 하고, 나머지는 짧게 기다렸다가 캐시를 다시 읽게 합니다. Redis 단일 primary를 stampede 완화용 mutex로 사용하는 예시는 다음과 같습니다.

    value = redis.get(cache_key)
    if value is not None:
        return value

    token = random_token()
    acquired = redis.set(lock_key, token, nx=True, px=2000)
    if acquired:
        try:
            value = load_from_database(entity_id)
            redis.set(cache_key, value, ex=300 + random_jitter())
            return value
        finally:
            release_lock_only_if_value_matches(lock_key, token)
    else:
        wait_briefly_and_retry_cache(cache_key)
        return bounded_fallback_or_error(entity_id)

락을 지울 때 단순히 DEL lock_key를 실행하면 안 됩니다. 첫 번째 요청의 작업이 TTL보다 오래 걸려 락이 만료된 뒤 두 번째 요청이 같은 락을 잡을 수 있기 때문입니다. 첫 번째 요청이 늦게 끝나며 DEL을 실행하면 두 번째 요청의 락을 지워버립니다. 따라서 소유자 token을 확인하는 짧은 Lua 스크립트나 원자적 compare-and-delete가 필요합니다.

이 방식의 목적은 결제 중복 방지 같은 정합성 보장이 아니라 원본 조회 폭발을 줄이는 것입니다. Redis 장애, 네트워크 분리, 락 TTL 만료가 생기면 두 요청이 동시에 원본을 읽을 수 있다는 전제를 둡니다. 원본 조회가 외부 효과를 만들면 loader를 멱등적으로 만들고, 비즈니스 정합성은 DB 제약조건이나 별도 idempotency 설계로 보호해야 합니다.

## stale-while-revalidate와 원본 보호

읽기 데이터가 잠시 오래되어도 되는 경우에는 만료 즉시 모든 요청을 miss로 만들지 않고, stale 값을 짧은 기간 제공하면서 백그라운드에서 갱신할 수 있습니다. 상품 설명이나 추천 결과에는 적용할 수 있지만, 잔액·재고·권한처럼 최신성이 중요한 값에는 허용 범위를 먼저 정의해야 합니다.

원본 보호도 필요합니다. single-flight가 실패하거나 hot key가 여러 개 동시에 만료되면 fallback 요청이 몰릴 수 있으므로 miss 경로에도 bulkhead, semaphore, timeout, 짧은 재시도를 둡니다. 캐시 갱신은 원본 변경 후 키를 삭제하고 다음 읽기에서 재생성하는 방식이 단순하지만, stale 허용 시간과 재생성 비용은 측정해야 합니다.

## 운영 지표와 선택 기준

전체 hit/miss뿐 아니라 key 또는 endpoint별 miss 증가율, 원본 fallback QPS, stampede 억제 횟수, 락 대기 시간, 원본 DB p95와 connection pool 대기를 봅니다. TTL 만료가 특정 분에 몰리는지도 확인해야 jitter 효과를 검증할 수 있습니다.

TTL jitter만으로 충분한 경우는 키가 고르게 분산되고 hot key가 거의 없으며 원본 miss를 감당할 여유가 있을 때입니다. 인기 키가 명확하면 single-flight를 추가하고, stale이 허용되면 stale-while-revalidate를 선택합니다. 캐시 값이 비즈니스 정합성의 최종 권위가 되어서는 안 되며, 락을 이용해 재고 차감이나 결제를 직렬화하려는 설계는 DB 트랜잭션과 별도로 검토해야 합니다.

정리하면 다음과 같습니다.

- TTL은 stale 시간을 제한하지만 만료 순간의 동시 조회를 막지는 않습니다.
- TTL jitter는 만료를 분산하고, single-flight는 같은 키의 원본 조회를 합칩니다.
- 락은 cache stampede 완화용으로 쓰고, 비즈니스 정합성은 다른 장치로 보장해야 합니다.
- hit rate 하나만 보지 말고 miss, 원본 fallback, 락 대기, DB pool을 함께 관찰해야 합니다.

## 참고한 공식 문서

- [Redis cache-aside pattern](https://redis.io/docs/latest/develop/use-cases/cache-aside/)
- [Redis cache-aside with node-redis and stampede protection](https://redis.io/docs/latest/develop/use-cases/cache-aside/nodejs/)
- [Redis distributed lock patterns](https://redis.io/docs/latest/develop/clients/patterns/distributed-locks/)
