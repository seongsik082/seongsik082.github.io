---
title: "Linux 파일 디스크립터가 고갈되면 커넥션 풀이 멀쩡해도 요청이 실패하는 이유"
date: 2026-07-16 08:50:00 +0900
tags: [Linux, Operations, Performance, Backend]
excerpt: "Linux에서 소켓·로그 파일·파이프·일반 파일은 모두 프로세스의 파일 디스크립터를 사용합니다. DB 커넥션 풀이 한도 안에 있어도 프로세스의 RLIMIT_NOFILE이나 시스템 전체 file-max가 먼저 차면 EMFILE과 연결 실패가 발생하므로, 사용량·한도·디스크립터 종류를 함께 확인해야 합니다."
---

## 문제 상황

배포 후 특정 인스턴스에서만 HTTP 요청이 간헐적으로 502나 연결 실패를 반환하는 장애가 있습니다. DB 커넥션 풀의 active 수는 최대치보다 낮고 CPU와 메모리도 여유가 있어 보입니다. 그런데 애플리케이션 로그에는 "Too many open files", "EMFILE", "accept failed" 같은 메시지가 섞여 있습니다. 이때 문제는 DB가 아니라 프로세스가 새 소켓이나 로그 파일을 열 수 없는 상태일 수 있습니다.

Linux에서 파일 디스크립터는 파일만 가리키는 번호가 아닙니다. TCP 연결, listening socket, pipe, epoll 인스턴스, 로그 파일, 임시 파일을 열 때도 프로세스가 디스크립터를 하나씩 사용합니다. 그래서 외부 API 호출이 늘거나 WebSocket 연결이 증가하거나, 닫히지 않은 파일 응답이 누적되는 것만으로도 DB 풀과 무관하게 장애가 발생할 수 있습니다.

## 프로세스 한도와 시스템 한도를 구분한다

프로세스가 새 디스크립터를 만들 수 있는지는 먼저 RLIMIT_NOFILE의 영향을 받습니다. 이 값은 프로세스가 열 수 있는 파일 디스크립터 수를 제한하며, 한도를 넘으면 파일 디스크립터를 할당하는 호출이 EMFILE로 실패합니다. soft limit은 현재 프로세스에 적용되는 값이고 hard limit은 soft limit을 올릴 수 있는 상한입니다.

반면 시스템 전체에는 커널이 할당할 수 있는 file handle 수를 나타내는 file-max가 있습니다. 프로세스별 EMFILE과 시스템 전체 VFS file-max limit reached는 확인 위치와 조정 범위가 다릅니다.

현재 프로세스의 제한과 사용량은 다음처럼 확인할 수 있습니다.

    PID=$(pgrep -n -f 'my-backend.jar')
    cat /proc/$PID/limits | grep -i 'open files'
    printf 'open_fds='
    find /proc/$PID/fd -maxdepth 1 -type l | wc -l
    cat /proc/sys/fs/file-nr
    cat /proc/sys/fs/file-max

proc/$PID/fd의 개수는 그 순간 프로세스가 실제로 보유한 디스크립터 수입니다. file-nr은 시스템 전체 파일 핸들 사용량을 판단하는 단서입니다. 이 숫자만 보고 바로 한도를 늘리기보다 애플리케이션이 어떤 종류의 디스크립터를 많이 들고 있는지 확인해야 합니다.

## 커넥션 풀이 정상인데도 HTTP가 깨지는 흐름

예를 들어 서비스의 DB 풀은 100개 중 60개만 사용 중이어도, inbound HTTP와 외부 API socket, 로그 파일이 합쳐져 이미 수천 개의 디스크립터를 사용할 수 있습니다. 여기에 임시 파일이나 pipe가 추가되면 DB 풀은 여유가 있어도 open files 한도에 먼저 도달합니다.

새로운 요청이 들어오면 서버는 accept를 위해 디스크립터를 만들어야 합니다. 이 작업이 실패하면 요청이 애플리케이션 코드의 컨트롤러까지 도달하지 못합니다. 따라서 애플리케이션의 일반적인 요청 로그가 줄고, 로드밸런서에서는 연결 거부·reset·502로 보일 수 있습니다. 동시에 이미 열린 DB 연결은 정상적으로 쿼리를 처리할 수 있어 “DB 풀은 정상”이라는 오해가 생깁니다.

반복해서 다음과 같은 패턴을 보면 파일 디스크립터를 우선 의심합니다.

- 특정 프로세스의 open fd 수가 시간에 따라 계속 증가합니다.
- 재시작 직후에는 정상이고 일정 시간 후 다시 실패합니다.
- 로그에 EMFILE, Too many open files, accept, socket이 나타납니다.
- 요청 수가 줄었는데도 outbound socket이나 일반 파일 수가 줄지 않습니다.
- DB 커넥션보다 HTTP, 메시지 브로커, 파일·pipe 디스크립터가 더 빠르게 늘어납니다.

## systemd 한도를 올릴 때의 순서

systemd로 실행하는 서비스라면 unit에 프로세스 한도를 명시할 수 있습니다.

    [Service]
    LimitNOFILE=65536

설정 후에는 실행 중인 프로세스의 /proc/$PID/limits에서 실제 반영 여부를 확인합니다. 컨테이너 환경에서는 systemd, runtime, orchestrator의 ulimit이 다를 수 있으므로 실제 애플리케이션 PID 기준으로 봐야 합니다.

한도를 65536이나 무제한으로 올리는 것은 누수를 고치는 방법이 아닙니다. 파일·소켓을 닫지 않는 버그가 있으면 더 오래 버티다가 더 큰 장애로 나타날 뿐입니다. 먼저 open fd 증가율과 종류를 확인하고, 그 다음 예상 동시 연결 수와 파일 사용량에 여유를 더해 한도를 정합니다. select 기반 라이브러리는 높은 디스크립터 번호에 제약이 있을 수 있으므로 사용하는 네트워크 라이브러리의 이벤트 모델도 확인해야 합니다.

## 장애 시 확인할 순서

첫째, 오류가 발생한 PID를 찾고 /proc/$PID/limits의 soft/hard open files 값과 fd 개수를 함께 기록합니다. 재시작 전후 수치를 비교해야 일시적인 피크인지 누적인지 구분할 수 있습니다.

둘째, lsof -p $PID 또는 /proc/$PID/fd의 링크 대상을 유형별로 집계합니다. 같은 원격 주소의 socket, 반복되는 로그 파일, anon_inode:[eventpoll]나 pipe 증가를 보고 ss -tanp와 pool 지표를 비교합니다.

셋째, 시스템 전체 file-nr와 커널 로그에서 file-max 경고를 확인합니다. 한 프로세스만 문제가 아니고 여러 서비스의 사용량이 함께 높다면 개별 서비스의 LimitNOFILE만 올려서는 해결되지 않습니다.

넷째, 원인을 제거한 뒤 부하 테스트로 같은 시간 동안 fd가 다시 증가하지 않는지 확인합니다. HTTP response body close 누락, 파일 스트림 미종료, 외부 클라이언트의 keep-alive 설정, 로그 appender 재연결, watcher 등록 누적처럼 코드와 라이브러리의 생명주기를 점검합니다.

## 운영 지표와 적용 기준

모니터링에는 프로세스별 open fd 수, 프로세스 한도 대비 비율, accept 오류 수, EMFILE 로그 수, inbound·outbound socket 수, DB·Redis·Kafka 연결 수를 포함합니다. 프로세스 open fd 비율이 70~80%를 넘는 시점부터 경고하고, 증가율이 지속되는 경우에는 절대 한도보다 먼저 알림을 내는 편이 좋습니다. 임계치는 트래픽과 재시작 시간에 맞춰 정하되, 실제 장애가 발생할 때까지 99%를 기다리면 안 됩니다.

정리하면 다음과 같습니다.

- 파일 디스크립터는 파일뿐 아니라 모든 소켓·pipe·epoll·로그 자원이 함께 사용합니다.
- DB 커넥션 풀이 여유 있어도 프로세스나 시스템 전체의 open files 한도가 먼저 찰 수 있습니다.
- EMFILE이 보이면 한도 증가 전에 PID별 fd 증가율과 종류를 확인해야 합니다.
- LimitNOFILE은 용량 계획의 안전 여유이지 파일·소켓 생명주기 누수를 대신 고치는 설정이 아닙니다.

## 참고한 공식 문서

- [Linux man-pages getrlimit](https://man7.org/linux/man-pages/man2/getrlimit.2.html)
- [Linux kernel /proc/sys/fs documentation](https://docs.kernel.org/admin-guide/sysctl/fs.html)
- [systemd.exec LimitNOFILE manual](https://man7.org/linux/man-pages/man5/systemd.exec.5.html)
