---
title: "PostgreSQL logical replication slot이 WAL을 붙잡는 방식과 CDC 장애 대응 순서"
date: 2026-07-15 08:50:00 +0900
tags: [PostgreSQL, CDC, Database, Operations, Backend]
excerpt: "PostgreSQL logical replication slot은 CDC 소비자가 잠시 멈춰도 필요한 WAL과 카탈로그 행을 보존합니다. restart_lsn, confirmed_flush_lsn, wal_status를 읽어 디스크 증가 원인을 확인하고, 슬롯 삭제·재구축·보존 한도 설정을 구분하는 운영 순서를 정리합니다."
---

## 문제 상황

PostgreSQL에 Debezium 같은 CDC 소비자를 붙인 뒤 어느 날 디스크 사용량이 급격히 늘어나는 장애가 있습니다. 애플리케이션 트래픽은 평소와 비슷하고 복제 연결도 한동안 정상으로 보였는데, 실제 원인은 며칠 전부터 멈춘 logical replication slot 하나일 수 있습니다. 일반적인 WAL 정리 규칙은 더 이상 필요하지 않은 파일을 checkpoint 이후 제거하지만, 슬롯이 아직 그 위치의 변경을 필요로 한다고 표시하면 PostgreSQL은 소비자가 나중에 읽을 수 있도록 WAL을 붙잡습니다.

## logical replication slot이 보존하는 것

Logical decoding은 테이블 변경을 WAL에서 읽어 소비자가 처리할 수 있는 연속적인 변경 스트림으로 바꾸는 기능입니다. logical replication slot은 특정 데이터베이스의 한 변경 스트림을 나타내며, 소비자별로 서로 다른 위치를 가질 수 있습니다. 슬롯은 연결이 끊겨도 독립적으로 지속되므로 장애가 복구될 때 마지막으로 확인한 위치부터 다시 읽을 수 있습니다.

핵심 필드는 다음처럼 해석합니다.

- restart_lsn: 이 슬롯의 소비자가 아직 필요로 할 수 있는 가장 오래된 WAL 위치입니다. 현재 WAL 위치와의 차이가 커질수록 슬롯이 보존을 요구하는 WAL이 많다는 뜻입니다.
- confirmed_flush_lsn: logical 소비자가 수신을 확인한 마지막 위치입니다. 이 값이 오랫동안 움직이지 않으면 소비 지연 또는 확인 응답 문제를 의심합니다.
- catalog_xmin: 슬롯이 필요로 하는 시스템 카탈로그의 가장 오래된 트랜잭션 위치입니다. WAL만이 아니라 VACUUM이 카탈로그 행을 치우지 못하게 만들 수도 있습니다.
- active: 현재 슬롯을 스트리밍하는 연결이 있는지 나타냅니다. false라고 해서 슬롯이 안전한 것은 아니며, 오히려 오래된 위치를 붙잡은 채 방치된 슬롯일 수 있습니다.
- wal_status와 safe_wal_size: 슬롯이 요구하는 WAL이 아직 보존되는지, lost 상태로 갈 위험까지 얼마나 남았는지 보여주는 신호입니다.

실제 운영에서는 슬롯별 상태를 데이터베이스의 현재 WAL 위치와 함께 조회합니다.

    SELECT
        slot_name,
        slot_type,
        active,
        restart_lsn,
        confirmed_flush_lsn,
        wal_status,
        safe_wal_size,
        pg_size_pretty(
            pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
        ) AS retained_wal,
        inactive_since
    FROM pg_replication_slots
    ORDER BY restart_lsn NULLS FIRST;

restart_lsn이 NULL인 초기 슬롯은 별도 상태로 표시하고, retained_wal의 절대 크기와 시간당 WAL 생성량을 함께 봅니다. 중요한 지표는 “현재 증가 속도로 몇 시간 후 디스크 한도에 도달하는가”입니다.

## 장애가 커지는 흐름

대표적인 흐름은 CDC 커넥터가 네트워크·권한·스키마 오류로 멈추고, 슬롯의 restart_lsn이 그대로인 동안 애플리케이션 쓰기가 계속되는 것입니다. 이후 pg_wal 사용량과 checkpoint 부담이 커지고, 보존 한도가 없으면 데이터베이스 저장 공간까지 잠식합니다.

PostgreSQL 문서의 pg_replication_slots 뷰에서 wal_status가 extended라면 일반적인 max_wal_size를 넘었지만 슬롯 또는 wal_keep_size 때문에 파일이 남아 있는 상태입니다. unreserved는 필요한 WAL을 슬롯이 더 이상 보존하지 못해 다음 checkpoint에서 제거될 수 있는 상태이고, lost는 슬롯을 더 이상 사용할 수 없다는 뜻입니다. max_slot_wal_keep_size를 설정하면 무한정 보존되는 위험을 줄일 수 있지만, 한도를 너무 작게 잡으면 소비자가 따라잡기 전에 필요한 WAL이 제거되어 CDC를 재동기화해야 할 수 있습니다.

PostgreSQL 18에는 idle_replication_slot_timeout도 있습니다. 일정 시간 사용되지 않은 슬롯을 무효화하는 장치지만 기본값은 비활성화되어 있고, 실제 무효화는 checkpoint 시점에 일어납니다. 이 설정을 켜는 것만으로 안전한 것은 아닙니다. 일시적인 장기 점검이나 리전 장애가 정상 복구 가능한 소비자를 무효화할 수 있으므로, 재스냅샷 비용과 복구 절차를 먼저 정해야 합니다.

## 슬롯을 발견했을 때의 대응 순서

디스크가 차오른다고 곧바로 슬롯을 삭제하면 안 됩니다. 먼저 슬롯 이름과 소유자를 커넥터 설정과 대조하고, 소비자 로그에서 마지막 처리 위치·역직렬화 오류·재시작 횟수를 확인합니다. 복구 가능한 소비자라면 정상화하여 따라잡게 하는 편이 데이터 손실을 줄입니다. 더 이상 사용하지 않는 슬롯만 관리자 승인 후 제거하며, 제거 전에는 초기 스냅샷과 변경분 재적용 절차를 확보합니다.

## 적용 기준과 운영 체크리스트

CDC를 운영한다면 슬롯을 연결 설정이 아니라 저장 공간을 사용하는 영속 상태로 관리해야 합니다. active, inactive_since, restart_lsn 지연, confirmed_flush_lsn 지연, wal_status, safe_wal_size, pg_wal 사용량을 수집하고, active=false보다 retained WAL 증가 속도와 safe_wal_size 감소를 알림 기준으로 삼습니다.

max_slot_wal_keep_size는 무제한 보존을 막는 안전망으로 검토할 수 있지만, 값은 “CDC 소비자가 최악의 장애 동안 따라잡는 데 필요한 WAL”과 “허용 가능한 재동기화 비용” 사이에서 정해야 합니다. 큰 값을 넣고 모니터링을 생략하면 디스크 장애를 늦출 뿐이고, 작은 값을 넣으면 슬롯이 lost가 되어 복구 작업이 더 커질 수 있습니다.

정리하면 다음과 같습니다.

- logical replication slot은 연결이 끊겨도 남으며, 소비자가 멈춘 위치의 WAL과 카탈로그 보존을 요구할 수 있습니다.
- active 여부만 보지 말고 restart_lsn, confirmed_flush_lsn, wal_status, safe_wal_size를 함께 읽어야 합니다.
- 장애 시 슬롯을 먼저 삭제하지 말고 소비자 복구 가능성, 데이터 누락 범위, 재동기화 비용을 확인해야 합니다.
- 보존 한도와 idle timeout은 운영 안전망이지 CDC 정합성을 대신하는 기능이 아닙니다.

## 참고한 공식 문서

- [PostgreSQL 18 Logical Decoding Concepts](https://www.postgresql.org/docs/current/logicaldecoding-explanation.html)
- [PostgreSQL 18 pg_replication_slots](https://www.postgresql.org/docs/current/view-pg-replication-slots.html)
- [PostgreSQL 18 Replication Configuration](https://www.postgresql.org/docs/current/runtime-config-replication.html)
