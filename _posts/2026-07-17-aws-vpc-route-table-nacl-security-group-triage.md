---
title: "VPC 연결 장애에서 Security Group만 보면 안 되는 이유: route table과 NACL 확인 순서"
date: 2026-07-17 08:52:00 +0900
tags: [AWS, VPC, Network, Security, Backend]
excerpt: "EC2에서 RDS나 내부 API로 연결되지 않을 때 Security Group이 맞아도 subnet route table, Network ACL, 반환 경로가 막혀 있을 수 있습니다. 목적지 route, subnet NACL, ENI Security Group, 응답 패킷 순서로 확인하는 장애 대응 절차를 정리합니다."
---

## 문제 상황

애플리케이션이 RDS의 5432 포트나 사설 API endpoint에 연결하지 못해 timeout이 발생했습니다. 보안 그룹에는 애플리케이션의 private CIDR에서 오는 5432 허용 규칙이 있고, 인스턴스에도 올바른 보안 그룹이 연결되어 있습니다. 그런데 같은 VPC의 다른 subnet에서는 연결되고 특정 subnet에서만 실패합니다.

이때 Security Group만 반복해서 확인하면 원인을 놓칩니다. 트래픽은 인스턴스에 도착하기 전에 subnet route table과 Network ACL을 통과하고, 응답 패킷은 반대 방향의 경로와 NACL 규칙을 다시 통과합니다.

## 패킷이 지나가는 순서를 그림으로 만든다

AWS VPC의 route table은 목적지 CIDR과 target을 보고 트래픽을 어디로 보낼지 결정합니다. public subnet이면 Internet Gateway, private subnet이면 NAT Gateway나 VPC peering, Transit Gateway, VPN 같은 target이 경로에 들어갈 수 있습니다. 각 subnet은 연결된 route table을 사용하고, 명시적 연결이 없으면 main route table을 사용합니다.

간단한 EC2 애플리케이션에서 RDS로 나가는 흐름은 다음처럼 생각할 수 있습니다.

    애플리케이션 ENI
      -> 소스 subnet route table
      -> VPC local route 또는 연결 target
      -> 목적지 subnet NACL inbound
      -> RDS ENI Security Group
      -> RDS 프로세스

응답은 RDS의 route table과 NACL outbound, 애플리케이션 subnet NACL inbound를 거쳐 돌아옵니다. Security Group은 ENI에 적용되고 stateful이므로 허용된 연결의 응답은 자동으로 허용됩니다. 반면 NACL은 stateless이므로 응답 방향의 ephemeral port도 열어야 합니다.

## Route table, NACL, Security Group의 차이

Route table은 패킷의 다음 이동 위치를 정하는 규칙입니다. 목적지 CIDR route가 없거나 NAT·peering·Transit Gateway target이 잘못되면 Security Group이 넓어도 패킷은 도착하지 않습니다.

Security Group은 인스턴스나 ENI 수준의 allow 규칙이며 stateful입니다. 일반적인 애플리케이션 접근 제어는 Security Group을 기본 수단으로 사용하는 것이 AWS의 권장 방향입니다. 소스 Security Group을 참조하면 IP 목록을 직접 관리하는 것보다 리소스 간 관계를 표현하기 쉽습니다.

Network ACL은 subnet 수준의 allow와 deny 규칙입니다. 규칙 번호가 낮은 것부터 평가하고 첫 번째 일치 규칙을 적용합니다. stateless이므로 요청 방향과 응답 방향을 모두 열어야 합니다. 특정 subnet 전체에 비상 차단을 걸거나 방어 계층을 추가하는 데 유용하지만, 애플리케이션별 세밀한 허용 정책을 모두 NACL에 넣으면 운영 복잡도가 커집니다.

예를 들어 애플리케이션이 RDS 5432로 나갈 때 다음을 모두 확인해야 합니다.

- 애플리케이션 subnet route table에 RDS subnet CIDR로 가는 local 또는 연결 경로가 있는가
- 애플리케이션 subnet NACL outbound가 목적지 5432를 허용하는가
- RDS subnet NACL inbound가 애플리케이션 CIDR와 5432를 허용하는가
- RDS의 ENI Security Group inbound가 실제 애플리케이션 SG 또는 CIDR를 허용하는가
- 응답 패킷의 ephemeral port가 양쪽 NACL의 반대 방향 규칙에 포함되는가

## 장애 시 확인 순서

첫째, DNS 이름이 올바른 IP로 해석되는지와 애플리케이션이 실제 어느 subnet과 ENI에서 나가는지 확인합니다. 그래야 올바른 route table을 검사할 수 있습니다.

둘째, source subnet의 route table association과 목적지 CIDR, target 상태를 확인합니다. 같은 VPC의 local route인지, NAT나 peering target이 available인지, 예상한 custom route table을 실제로 쓰는지 봅니다.

셋째, source와 destination subnet의 NACL을 낮은 rule number부터 읽습니다. 요청 방향만 열고 반환 port를 닫은 설정, 명시적 deny가 앞 번호에 있는 설정, IPv4만 열고 IPv6 경로를 놓친 설정이 자주 발생합니다.

넷째, 양쪽 ENI의 Security Group과 실제 source를 확인합니다. 로드밸런서 뒤의 애플리케이션이라면 RDS가 보는 source가 클라이언트 IP인지 다른 ENI인지 배치에 따라 달라질 수 있습니다. 규칙에 올바른 security group reference를 사용했는지도 확인합니다.

다섯째, VPC Flow Logs의 ACCEPT와 REJECT를 source ENI, destination ENI, port, action 기준으로 확인합니다. Flow Logs는 모든 애플리케이션 오류를 설명하지는 않지만, 어느 방향에서 거부됐는지 좁히는 데 도움이 됩니다. 패킷이 허용됐는데도 timeout이면 route target, listen 상태, return path를 다음으로 봅니다.

## 운영 기준과 피해야 할 설정

기본 runbook에 route table, NACL, Security Group 세 계층을 모두 넣습니다. 변경 시 association, NACL rule number, SG rule source를 함께 리뷰하고 Flow Logs로 검증합니다. 0.0.0.0/0와 넓은 port range를 임시로 열었다면 원인 확인 뒤 즉시 되돌립니다.

NACL은 subnet 전체에 적용되므로 공유 subnet에서 특정 서비스의 예외를 추가하면 다른 서비스의 반환 트래픽을 깨뜨릴 수 있습니다. 애플리케이션별 접근 제어가 목적이면 Security Group을 먼저 정리하고, NACL은 subnet guard rail이나 비상 차단에 제한하는 것이 안전합니다.

정리하면 다음과 같습니다.

- Route table은 패킷의 다음 target을 정하고, Security Group과 NACL은 통과 여부를 결정합니다.
- Security Group은 리소스 수준 stateful allow이고, NACL은 subnet 수준 stateless 규칙입니다.
- timeout 장애에서는 source route, 양쪽 NACL, 양쪽 ENI Security Group, 반환 경로 순서로 확인합니다.
- VPC Flow Logs와 실제 subnet association을 함께 보지 않으면 콘솔의 규칙만 보고 잘못된 결론을 내릴 수 있습니다.

## 참고한 공식 문서

- [AWS VPC route tables](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html)
- [AWS VPC network ACLs](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html)
- [AWS VPC infrastructure security and SG/NACL comparison](https://docs.aws.amazon.com/vpc/latest/userguide/infrastructure-security.html)
- [AWS VPC flow logs and traffic privacy](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Security.html)
