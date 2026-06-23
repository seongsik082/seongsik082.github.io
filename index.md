---
layout: default
title: Home
---

<section class="hero">
  <p class="eyebrow">Backend Developer</p>
  <h1>안정적인 API와 데이터 흐름을 설계하는 백엔드 개발자 김성식입니다.</h1>
  <p class="hero-summary">
    Java, Spring Boot, 데이터베이스, 인프라를 중심으로 서비스의 핵심 흐름을 만들고 기록합니다.
    이 블로그는 제가 만든 프로젝트와 문제 해결 과정을 정리하는 공간입니다.
  </p>
  <div class="hero-actions">
    <a href="/about/">소개 보기</a>
    <a href="/projects/">프로젝트 보기</a>
    <a href="https://github.com/seongsik082">GitHub</a>
  </div>
</section>

<section class="section-grid">
  <div>
    <p class="section-label">Focus</p>
    <h2>관심 있는 백엔드 주제</h2>
  </div>
  <div class="tag-list">
    <span>API 설계</span>
    <span>Spring Boot</span>
    <span>JPA</span>
    <span>MySQL</span>
    <span>Redis</span>
    <span>Docker</span>
    <span>CI/CD</span>
    <span>성능 개선</span>
  </div>
</section>

<section>
  <div class="section-head">
    <div>
      <p class="section-label">Writing</p>
      <h2>최근 글</h2>
    </div>
    <a class="text-link" href="/archive/">전체 글</a>
  </div>

  <div class="post-list">
    {% for post in site.posts limit: 4 %}
      <article class="post-card">
        <time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y.%m.%d" }}</time>
        <h3><a href="{{ post.url | relative_url }}">{{ post.title }}</a></h3>
        <p>{{ post.excerpt | strip_html | truncate: 120 }}</p>
        <div class="post-tags">
          {% for tag in post.tags %}
            <span>{{ tag }}</span>
          {% endfor %}
        </div>
      </article>
    {% endfor %}
  </div>
</section>
