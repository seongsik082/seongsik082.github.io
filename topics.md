---
layout: default
title: Topics
permalink: /topics/
---

<section class="page-title">
  <p class="eyebrow">Topics</p>
  <h1>백엔드 개발 주제를 영역별로 모아봅니다.</h1>
  <p class="page-description">
    시간순으로 글을 읽기보다, Java, Spring, API, Database, 운영 주제처럼 문제 영역별로 탐색하고 싶다면 이 페이지에서 시작하면 됩니다.
  </p>
</section>

<section class="guide-grid">
  <article class="guide-card">
    <p class="section-label">Java</p>
    <h2>동시성, 스레드, 비동기 처리</h2>
    <p>애플리케이션 코드 안에서 바로 체감되는 지연, 스레드 풀, 비동기 흐름 문제를 중심으로 읽을 수 있습니다.</p>
    <div class="topic-meta">
      <strong>{{ site.tags.Java | size | default: 0 }} posts</strong>
      <a href="{{ '/posts/?tag=Java' | relative_url }}">Java 글 보기</a>
    </div>
  </article>

  <article class="guide-card">
    <p class="section-label">Spring / JPA</p>
    <h2>서비스 계층, 트랜잭션, 지연 로딩</h2>
    <p>Spring 서비스 경계, JPA 지연 로딩, N+1, OSIV처럼 프레임워크 동작과 쿼리 흐름이 만나는 지점을 다룹니다.</p>
    <div class="topic-meta">
      <strong>{{ site.tags.Spring | size | plus: site.tags.JPA | size }} related posts</strong>
      <a href="{{ '/posts/?tag=Spring' | relative_url }}">Spring 글 보기</a>
    </div>
  </article>

  <article class="guide-card">
    <p class="section-label">REST API</p>
    <h2>상태 코드, 조건부 요청, 중복 방지</h2>
    <p>클라이언트와 서버의 약속을 어떻게 운영 가능한 형태로 만들지에 초점을 맞춘 글들입니다.</p>
    <div class="topic-meta">
      <strong>{{ site.tags.API | size | plus: site.tags.HTTP | size | plus: site.tags['REST API'] | size }} related posts</strong>
      <a href="{{ '/posts/?tag=REST%20API' | relative_url }}">API 글 보기</a>
    </div>
  </article>

  <article class="guide-card">
    <p class="section-label">Database</p>
    <h2>정합성, 인덱스, 격리 수준, 락</h2>
    <p>성능과 정합성이 함께 걸리는 데이터 영역을 모았습니다. 실무에서 버그와 장애가 자주 시작되는 영역입니다.</p>
    <div class="topic-meta">
      <strong>{{ site.tags.Database | size | plus: site.tags.Transaction | size }} related posts</strong>
      <a href="{{ '/posts/?tag=Database' | relative_url }}">Database 글 보기</a>
    </div>
  </article>

  <article class="guide-card">
    <p class="section-label">Distributed Systems</p>
    <h2>재시도, 멱등성, 중복 실행 방지</h2>
    <p>단일 서버 관점에서 놓치기 쉬운 재시도와 분산 환경의 중복 실행 문제를 다룹니다.</p>
    <div class="topic-meta">
      <strong>{{ site.tags['Distributed Systems'] | size | default: 0 }} posts</strong>
      <a href="{{ '/posts/?tag=Distributed%20Systems' | relative_url }}">분산 시스템 글 보기</a>
    </div>
  </article>

  <article class="guide-card">
    <p class="section-label">Operations</p>
    <h2>배포, 관측성, 운영 판단 기준</h2>
    <p>서비스를 실제로 운영할 때 어떤 신호를 보고 어디서 병목을 찾는지에 초점을 맞춘 글들입니다.</p>
    <div class="topic-meta">
      <strong>{{ site.tags.Observability | size | plus: site.tags.Kubernetes | size | plus: site.tags['CI/CD'] | size | plus: site.tags.AWS | size }} related posts</strong>
      <a href="{{ '/posts/?tag=Observability' | relative_url }}">운영 글 보기</a>
    </div>
  </article>
</section>

<section class="home-section">
  <div class="section-kicker">전체 태그</div>
  <div class="section-head compact">
    <h2>세부 주제를 태그로 탐색해보세요</h2>
    <a class="text-link" href="{{ '/posts/' | relative_url }}">전체 목록 보기</a>
  </div>

  <div class="topic-cloud">
    {% assign sorted_tags = site.tags | sort %}
    {% for tag in sorted_tags %}
      {% assign encoded_tag = tag[0] | url_encode %}
      <a href="{{ '/posts/' | relative_url }}?tag={{ encoded_tag }}">
        #{{ tag[0] }}
        <span>{{ tag[1] | size }}</span>
      </a>
    {% endfor %}
  </div>
</section>
