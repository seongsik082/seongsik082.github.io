---
layout: default
title: Start Here
permalink: /start-here/
---

{% assign topic_paths = site.data.topic_paths %}

<section class="page-title">
  <p class="eyebrow">Start Here</p>
  <h1>처음 방문했다면, 백엔드 주제별로 이런 순서로 읽어보세요.</h1>
  <p class="page-description">
    이 블로그는 시간순 기록보다, 주니어에서 미들 백엔드 개발자로 넘어갈 때 필요한
    판단 기준을 쌓는 방향으로 글을 정리하고 있습니다.
  </p>
</section>

<section class="start-steps">
  <article class="step-card">
    <p class="section-label">Step 01</p>
    <h2>요청과 응답부터 보기</h2>
    <p>API 설계, 상태 코드, 조건부 요청처럼 클라이언트와 서버의 약속이 어떻게 만들어지는지 먼저 이해하면 나머지 주제를 읽기 쉬워집니다.</p>
  </article>
  <article class="step-card">
    <p class="section-label">Step 02</p>
    <h2>데이터와 트랜잭션 보기</h2>
    <p>정합성, 인덱스, 락, 격리 수준은 실제 장애와 가장 자주 연결되는 영역이라 초반에 잡아두는 편이 좋습니다.</p>
  </article>
  <article class="step-card">
    <p class="section-label">Step 03</p>
    <h2>운영과 관측으로 확장하기</h2>
    <p>성능, 재시도, 관측성, 배포 같은 주제는 "돌아간다"를 넘어 "운영할 수 있다"로 넘어가는 구간입니다.</p>
  </article>
</section>

<section class="guide-grid">
  {% for topic in topic_paths %}
    <article class="guide-card">
      <p class="section-label">{{ topic.label }}</p>
      <h2>{{ topic.title }}</h2>
      <p>{{ topic.start_description }}</p>
      <div class="mini-post-list">
        {% assign shown_posts = 0 %}
        {% for post in site.posts %}
          {% assign matches_topic = false %}
          {% for tag in topic.tags %}
            {% if post.tags contains tag %}
              {% assign matches_topic = true %}
              {% break %}
            {% endif %}
          {% endfor %}
          {% if matches_topic %}
            <a href="{{ post.url | relative_url }}">{{ post.title }}</a>
            {% assign shown_posts = shown_posts | plus: 1 %}
          {% endif %}
          {% if shown_posts >= topic.post_limit %}
            {% break %}
          {% endif %}
        {% endfor %}
      </div>
    </article>
  {% endfor %}

  <article class="guide-card">
    <p class="section-label">Next</p>
    <h2>전체 글을 태그로 확장해서 보기</h2>
    <p>특정 영역을 더 깊게 보고 싶다면 전체 글 목록에서 태그와 검색으로 확장해보는 방식이 가장 빠릅니다.</p>
    <div class="hero-actions">
      <a href="{{ '/posts/' | relative_url }}">전체 글 목록</a>
      <a href="{{ '/projects/' | relative_url }}">프로젝트 방향</a>
    </div>
  </article>
</section>
