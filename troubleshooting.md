---
layout: default
title: Troubleshooting
permalink: /troubleshooting/
description: "느린 응답, 정합성 오류, 인증 실패, 배포 흔들림처럼 운영 증상 기준으로 백엔드 글을 다시 찾는 허브입니다."
---

{% assign routes = site.data.troubleshooting_paths %}

<section class="page-title">
  <p class="eyebrow">Troubleshooting</p>
  <h1>기술 이름보다 운영 증상으로 글을 다시 찾습니다.</h1>
  <p class="page-description">
    백엔드 문제는 Java, Spring, Database처럼 기술별로만 오지 않습니다. 느린 응답, 가끔 어긋나는 데이터, 인증 실패, 배포 직후 흔들림처럼
    운영에서 먼저 보이는 증상 기준으로 읽기 경로를 묶었습니다.
  </p>
</section>

<section class="archive-guides" aria-label="Troubleshooting routes">
  {% for route in routes %}
    <a class="archive-guide-card" href="#{{ route.key }}">
      <strong>{{ route.label }}</strong>
      <span>{{ route.title }}</span>
    </a>
  {% endfor %}
</section>

<section class="guide-grid section-stack">
  {% for route in routes %}
    <article class="guide-card" id="{{ route.key }}">
      <p class="section-label">{{ route.label }}</p>
      <h2>{{ route.title }}</h2>
      <p>{{ route.description }}</p>

      <p class="list-heading">이럴 때 먼저 보기</p>
      <p>{{ route.start_with }}</p>

      <p class="list-heading">먼저 확인할 것</p>
      <ul class="check-list">
        {% for item in route.watch_items %}
          <li>{{ item }}</li>
        {% endfor %}
      </ul>

      <p class="list-heading">관련 글</p>
      <div class="mini-post-list">
        {% for slug in route.slugs %}
          {% for post in site.posts %}
            {% if post.slug == slug %}
              <a href="{{ post.url | relative_url }}">{{ post.title }}</a>
            {% endif %}
          {% endfor %}
        {% endfor %}
      </div>
    </article>
  {% endfor %}
</section>

<section class="home-section">
  <div class="section-kicker">Next</div>
  <div class="section-head compact">
    <h2>기술 주제 기준으로도 이어서 볼 수 있습니다.</h2>
    <a class="text-link" href="{{ '/topics/' | relative_url }}">주제 허브 보기</a>
  </div>

  <div class="reading-grid">
    <a class="reading-card" href="{{ '/topics/' | relative_url }}">
      <p class="section-label">Topics</p>
      <h3>기술별 주제로 탐색</h3>
      <p>Java, Spring, REST API, Database처럼 기술 영역 중심으로 다시 좁혀 볼 수 있습니다.</p>
    </a>
    <a class="reading-card" href="{{ '/posts/' | relative_url }}">
      <p class="section-label">Archive</p>
      <h3>검색과 태그로 전체 보기</h3>
      <p>글 제목이나 세부 태그가 기억난다면 전체 글 목록에서 바로 검색하는 편이 빠릅니다.</p>
    </a>
  </div>
</section>
