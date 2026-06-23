---
layout: default
title: Home
---

<section class="hero">
  <p class="eyebrow">Backend Developer · 김성식</p>
  <h1>백엔드 개발자로 성장하며 마주친 문제와 해결 과정을 기록합니다.</h1>
  <p class="hero-summary">
    Java, Spring Boot, 데이터베이스, 인프라를 중심으로 서비스의 핵심 흐름을 만들고 기록합니다.
    만든 것보다 왜 그렇게 만들었는지, 어디서 막혔고 어떻게 풀었는지를 남기는 블로그입니다.
  </p>
  <div class="hero-actions">
    <a href="/posts/">글 목록</a>
    <a href="/projects/">프로젝트</a>
    <a href="https://github.com/seongsik082">GitHub</a>
  </div>
</section>

<section class="topic-strip">
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
    <a class="text-link" href="/posts/">전체 글</a>
  </div>

  <div class="post-list">
    {% for post in site.posts limit: 4 %}
      <article class="post-row">
        <a href="{{ post.url | relative_url }}">
          <div class="post-row-body">
            <div class="post-tags">
              {% for tag in post.tags limit: 2 %}
                <span>{{ tag }}</span>
              {% endfor %}
            </div>
            <h3>{{ post.title }}</h3>
            <p>{{ post.excerpt | strip_html | truncate: 120 }}</p>
          </div>
          <time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y.%m.%d" }}</time>
        </a>
      </article>
    {% endfor %}
  </div>
</section>

<section>
  <div class="section-head">
    <div>
      <p class="section-label">Portfolio</p>
      <h2>프로젝트 기록</h2>
    </div>
    <a class="text-link" href="/projects/">전체 프로젝트</a>
  </div>

  <div class="note-panel">
    <p>
      프로젝트 페이지에는 API 설계, 데이터 모델링, 인증/인가, 성능 개선, 배포 자동화처럼
      백엔드 개발자로서 보여줄 수 있는 기술 판단을 정리합니다.
    </p>
  </div>
</section>
