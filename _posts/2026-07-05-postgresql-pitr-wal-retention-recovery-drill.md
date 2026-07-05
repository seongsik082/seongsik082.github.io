---
title: "PostgreSQL PITR를 믿고도 복구에 실패하는 팀이 WAL 보관과 복구 리허설을 놓치는 이유"
date: 2026-07-05 08:58:00 +0900
tags: [PostgreSQL, Database, Backend]
excerpt: "PostgreSQL PITR은 base backup만 있으면 되는 기능이 아닙니다. 백업 시작 시점까지 이어지는 WAL, 안전한 archive 설정, 정기 복구 리허설이 함께 있어야 실제 장애 때 원하는 시점으로 돌아갈 수 있습니다."
---

## 문제 상황

운영 중인 주문 DB에서 누군가 배치 스크립트를 잘못 돌려 오전 8시 47분 이후 데이터가 깨졌다고 가정해 보겠습니다. 백업 담당자는 "어제 새벽 base backup도 있고, WAL archive도 켜 놨으니 8시 46분으로 되돌리면 된다"고 말합니다.

그런데 실제 복구를 시작하면 예상보다 자주 막힙니다. 복구 서버는 `restore_command`로 필요한 WAL 파일을 찾지 못하고 멈추거나, 백업은 있는데 복구 목표 시각까지 이어지는 WAL 체인이 비어 있습니다. 더 나쁜 경우는 archive 저장소에 파일은 남아 있는데 다른 서버가 같은 경로에 덮어써서, 이름은 맞지만 내용이 틀린 WAL이 섞여 있기도 합니다.

이런 사고가 생기는 이유는 PITR을 "백업 파일 하나"로 이해하기 때문입니다. PostgreSQL의 point-in-time recovery는 base backup, 그 시점 이후의 연속된 WAL, 그리고 그 둘을 실제로 다시 조립해 본 복구 절차가 모두 맞아야 성립합니다. 셋 중 하나라도 비어 있으면 장애 당일에야 "복구가 가능한 줄만 알았다"는 사실이 드러납니다.

## 핵심 개념

PostgreSQL 공식 문서는 PITR이 파일 시스템 수준의 base backup과 WAL 보관을 결합하는 방식이라고 설명합니다. 핵심은 백업 파일이 아니라 "base backup 시작 시점까지 끊기지 않는 WAL 연속성"입니다. 공식 문서도 복구 성공을 위해서는 backup 시작 시점까지 이어지는 continuous sequence of archived WAL files가 필요하다고 분명히 적고, 첫 base backup을 뜨기 전에 archive 절차를 먼저 구성하고 테스트하라고 권장합니다.

또 하나 놓치기 쉬운 점은 `pg_dump`가 PITR 재료가 아니라는 점입니다. `pg_dump`와 `pg_dumpall`은 논리 백업이라 WAL replay에 필요한 정보가 없어서, PostgreSQL 문서상 continuous archiving 해법의 일부로 사용할 수 없습니다. "논리 백업도 있으니 최악이면 그걸로 복구하지"라는 생각은 일부 테이블 재구성에는 도움이 될 수 있어도, 특정 시점 전체 클러스터 복구를 대신하지는 못합니다.

WAL archive의 성공 기준도 엄격합니다. `archive_command`는 성공했을 때만 0을 반환해야 하고, PostgreSQL은 그때만 해당 WAL을 안전하게 archive 되었다고 간주합니다. 이미 있는 파일을 무심코 덮어쓰는 스크립트는 특히 위험합니다. 문서도 archive 명령은 기존 archive 파일을 덮어쓰지 않도록 설계하라고 강조합니다.

마지막으로 저트래픽 서비스에서는 `archive_timeout`이 복구 가능 시점의 세밀도를 좌우합니다. WAL archive는 기본적으로 "가득 찬 세그먼트"를 기준으로 수행되므로, 트래픽이 적으면 커밋 후 오랫동안 archive가 안 될 수 있습니다. PostgreSQL 문서는 이런 지연을 제한하려면 `archive_timeout`을 둘 수 있지만, 너무 짧게 잡으면 archive 저장소가 빠르게 불어난다고 경고합니다.

## 설정으로 보기

운영에서 많이 보는 최소 구성은 아래와 비슷합니다.

```conf
# postgresql.conf
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /backup/wal/%f && cp %p /backup/wal/%f'
archive_timeout = 60s
```

이 설정의 의미를 실무적으로 풀면 이렇습니다.

- `wal_level=replica`: 복구와 복제를 위한 WAL 정보를 충분히 남깁니다.
- `archive_mode=on`: 완료된 WAL 세그먼트를 archive 대상으로 만듭니다.
- `archive_command`: 같은 이름의 기존 파일을 덮어쓰지 않도록 방어합니다.
- `archive_timeout=60s`: 저트래픽 시간대에도 너무 오래 archive가 밀리지 않게 상한을 둡니다.

복구 절차에서도 중요한 것은 "서버를 다시 켜 본다"가 아니라 복구 목표를 명시하는 것입니다.

```conf
# postgresql.conf on recovery host
restore_command = 'cp /backup/wal/%f %p'
recovery_target_time = '2026-07-05 08:46:59+09'
recovery_target_timeline = 'latest'
```

그리고 데이터 디렉터리에는 `recovery.signal` 파일이 필요합니다. PostgreSQL 문서는 복구 시 `restore_command`가 반드시 있어야 하며, 필요한 WAL을 archive에서 가져와 replay한다고 설명합니다. 즉, 복구 테스트는 "백업 압축 파일이 열리는지"가 아니라 "원하는 시각까지 실제로 replay가 진행되는지"를 검증해야 합니다.

## 자주 하는 실수

첫 번째 실수는 base backup 성공만 체크하고 복구 리허설을 생략하는 것입니다. 백업 자동화 로그가 초록색이어도, 복구 서버에서 `recovery.signal`, `restore_command`, WAL 접근 권한, timeline 선택까지 맞춰 보지 않으면 실제 재난 복구 성공 여부를 알 수 없습니다.

두 번째 실수는 WAL 보관 기간을 스냅샷 보관 기간보다 짧게 가져가는 것입니다. base backup은 7일 남기는데 WAL은 2일치만 남기면, 5일 전 backup은 존재해도 실제 PITR은 이미 불가능합니다. 복구 목표 시각을 만족하려면 "가장 오래 살려 둘 base backup을 커버하는 WAL 체인"이 남아 있어야 합니다.

세 번째 실수는 archive 저장소를 덮어쓰기 가능하게 두는 것입니다. PostgreSQL 문서도 다른 서버의 출력이 같은 archive 디렉터리로 섞이는 상황을 대표적 위험으로 언급합니다. 환경별 prefix 분리, overwrite 방지, immutable 저장소 정책이 필요한 이유입니다.

네 번째 실수는 저트래픽 서비스에서 `archive_timeout` 없이 "RPO가 거의 0에 가깝다"고 말하는 것입니다. 트랜잭션은 끝났어도 WAL 세그먼트가 아직 닫히지 않았다면, 그 시점 데이터는 외부 archive에 안전하게 보관되지 않았을 수 있습니다.

## 언제 쓰면 좋은가

PITR은 결제, 주문, 회원, 재고처럼 "특정 시각 직전 상태"로 되돌릴 수 있어야 하는 서비스에서 사실상 기본 선택지에 가깝습니다. 실수 삭제, 잘못된 배치, 애플리케이션 버그로 인한 대량 손상은 모두 "어제 새벽 상태"가 아니라 "오전 8시 46분 59초" 같은 더 촘촘한 복구 지점을 요구하기 쉽기 때문입니다.

반대로 운영 부담이 작은 시스템이라면 관리형 서비스의 자동 백업과 스냅샷만으로 충분할 수 있습니다. 다만 이 경우에도 실제 RPO와 복구 시간 목표를 분명히 해야 합니다. "복구는 된다"가 아니라 "몇 분 단위까지 되돌릴 수 있는가, 복구 절차를 몇 번 검증했는가"가 판단 기준입니다.

실무에서 바로 쓰기 좋은 한 줄 기준은 이것입니다. "마지막 복구 리허설에서 우리가 원하는 시각으로 실제 데이터를 열어 봤는가?" 이 질문에 답이 없으면 PITR은 구성된 것이 아니라 기대 중인 상태입니다.

## 운영에서 볼 것

- `pg_stat_archiver`로 archiver가 정상적으로 WAL을 내보내고 있는지
- `pg_wal/` 디렉터리 사용량이 비정상적으로 커지지 않는지
- archive 저장소에서 최근 WAL 업로드 시각이 얼마나 뒤처지는지
- base backup 보관 주기와 WAL 보관 주기가 실제로 연결되는지
- 월 1회 이상 복구 리허설에서 `recovery_target_time` 기준 검증이 통과하는지

장애 대응 때는 "백업이 있나"보다 "원하는 시각까지 이어지는 WAL이 있나"를 먼저 확인해야 합니다. PITR 실패는 복구 명령을 몰라서가 아니라, 평소에 archive 연속성과 리허설을 운영 지표로 보지 않아서 생기는 경우가 많습니다.

## 정리

PostgreSQL PITR은 base backup 하나로 끝나는 기능이 아닙니다. backup 시작 시점까지 이어지는 WAL, 덮어쓰지 않는 archive 절차, 복구 목표 시각까지 실제 replay를 검증한 리허설이 함께 있어야 합니다. 운영에서 진짜 중요한 질문은 "백업을 떴는가"가 아니라 "지금 바로 특정 시각으로 되돌릴 수 있는가"입니다.

## 참고한 공식 문서

- [PostgreSQL 18 Docs: Continuous Archiving and Point-in-Time Recovery (PITR)](https://www.postgresql.org/docs/current/continuous-archiving.html)
- [PostgreSQL 18 Docs: The Cumulative Statistics System](https://www.postgresql.org/docs/current/monitoring-stats.html)
