---
layout: default
title: About
permalink: /about/
---

{% assign career = site.data.portfolio.career %}

<section class="page-title">
  <p class="eyebrow">About</p>
  <h1>문제를 끝까지 추적하고, 운영에서 다시 설명할 수 있을 만큼 이해하려고 합니다.</h1>
  <p class="page-description">
    {{ career.duration }}간 Java/Spring Boot 웹서비스를 개선하고 운영해 온 백엔드 개발자 김성식입니다.
  </p>
  <div class="link-row">
    <a href="{{ site.author.resume_url }}">이력서</a>
    <a href="{{ site.author.portfolio_url }}">포트폴리오</a>
    <a href="https://github.com/{{ site.author.github }}">GitHub</a>
    <a href="mailto:{{ site.author.email }}">이메일</a>
  </div>
</section>

<section class="content">
  <h2>소개</h2>
  <p>
    서비스의 요청 흐름, 데이터 모델, 장애 가능성, 운영 자동화에 관심이 있습니다.
    기능을 빠르게 만드는 것뿐 아니라, 나중에 읽히고 고칠 수 있는 구조를 만드는 개발자가 되고 싶습니다.
  </p>
  <p>
    실무에서는 고객 요청을 분석해 기능을 개선하고, 대용량 조회와 파일 다운로드처럼 데이터가 늘어날수록
    드러나는 문제를 해결했습니다. 코드를 고친 뒤에는 테스트와 운영 반영, 반영 후 확인까지 직접 챙겼습니다.
  </p>

  <h2>경력</h2>
  <div class="career-item">
    <div class="career-head">
      <strong>{{ career.company }} · {{ career.team }}</strong>
      <span>{{ career.period }} ({{ career.duration }})</span>
    </div>
    <p>{{ career.role }}</p>
    <ul>
      {% for duty in career.duties %}
        <li>{{ duty }}</li>
      {% endfor %}
    </ul>
    <p class="card-stack">{{ career.stack }}</p>
  </div>
  <p>
    구체적인 문제 해결 사례는 <a href="{{ '/projects/' | relative_url }}">Projects</a>에 문제 · 접근 · 결과 순서로 정리했습니다.
  </p>

  <h2>기술 스택</h2>
  <dl class="skill-list">
    {% for group in site.data.portfolio.skills %}
      <div>
        <dt>{{ group.level }}</dt>
        <dd>
          {% for item in group.items %}<span>{{ item }}</span>{% endfor %}
        </dd>
      </div>
    {% endfor %}
  </dl>

  <h2>일하는 방식</h2>
  <ul>
    <li>요구사항을 API, 데이터, 예외 흐름으로 나누어 정리합니다.</li>
    <li>동작하는 코드 이후에 테스트, 로그, 배포 흐름까지 확인합니다.</li>
    <li>여러 요청이 동시에 들어오면 기한과 영향도로 우선순위를 정하고 담당자와 일정을 맞춥니다.</li>
    <li>트러블슈팅 과정은 재현 조건, 원인, 해결, 재발 방지 순서로 기록합니다.</li>
  </ul>

  <h2>이 블로그에 대해</h2>
  <p>
    "어떤 개념인가"보다 "어디서 문제를 만나고, 어떤 기준으로 선택하며, 운영에서 무엇을 먼저 확인해야 하는가"를
    함께 남기려고 합니다. Java, Spring Boot, JPA, HTTP API, 데이터베이스, 캐시, 비동기 처리, 배포 자동화,
    관측성과 성능 이슈를 중심으로 글을 쌓고 있습니다.
  </p>
  <p>
    처음 방문했다면 <a href="{{ '/start-here/' | relative_url }}">Start Here</a>에서 주제별 읽는 순서를,
    <a href="{{ '/posts/' | relative_url }}">Posts</a>에서 태그와 검색으로 전체 글을 볼 수 있습니다.
  </p>
</section>
