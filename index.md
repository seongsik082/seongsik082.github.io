---
layout: default
title: Home
---

{% assign topic_paths = site.data.topic_paths %}

<section class="home-hero">
  <div class="home-hero-inner">
    <p class="eyebrow">Backend Developer Blog</p>
    <h1>백엔드 개발의 기본기와 문제 해결을 기록합니다.</h1>
    <p class="home-hero-summary">
      Java, Spring, Network, Database를 중심으로 공부한 개념과 구현하며 마주친 시행착오를 정리합니다.
    </p>
  </div>
</section>

<section class="profile-intro">
  <p>
    이 블로그는 백엔드 개발자로 성장하며 남기는 학습 노트입니다.
    기능 구현보다 요청 흐름, 데이터 처리, 예외 상황, 운영 관점까지 함께 이해하는 것을 목표로 합니다.
  </p>
</section>

<section class="home-topics">
  {% if topic_paths %}
    {% for topic in topic_paths %}
      <a href="{{ '/posts/' | relative_url }}?topic={{ topic.key }}">{{ topic.chip_label | default: topic.label }}</a>
    {% endfor %}
  {% else %}
    <a href="{{ '/posts/' | relative_url }}?tag=Backend">Backend</a>
    <a href="{{ '/posts/' | relative_url }}?tag=Java">Java</a>
    <a href="{{ '/posts/' | relative_url }}?tag=Spring">Spring</a>
    <a href="{{ '/posts/' | relative_url }}?tag=Database">Database</a>
  {% endif %}
</section>

<section class="home-section">
  <div class="section-kicker">새로운 소식</div>
  <div class="section-head compact">
    <h2>최근 작성한 글</h2>
    <a class="text-link" href="{{ '/posts/' | relative_url }}">더 살펴보기</a>
  </div>

  <div class="post-list featured-posts">
    {% for post in site.posts limit: 6 %}
      <article class="post-row">
        <a href="{{ post.url | relative_url }}">
          <div class="post-row-body">
            <div class="post-category">
              {% for tag in post.tags limit: 2 %}
                <span>{{ tag }}</span>
              {% endfor %}
            </div>
            <h3>{{ post.title }}</h3>
            <p>{{ post.excerpt | strip_html | truncate: 135 }}</p>
            <time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y.%m.%d" }}</time>
          </div>
        </a>
      </article>
    {% endfor %}
  </div>
</section>
