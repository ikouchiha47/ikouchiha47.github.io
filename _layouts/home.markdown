---
layout: default
---

<!-- Page Header -->
<header class="masthead" style="background: #000; position: relative; overflow: hidden;">
  <canvas id="voronoi-bg" style="position: absolute; top: 0; left: 0; width: 100%; height: 100%; z-index: 0;"></canvas>
  <div class="overlay" style="z-index: 1;"></div>
  <div class="container" style="position: relative; z-index: 2;">
    <div class="row">
      <div class="col-lg-8 col-md-10 mx-auto">
        <div class="page-heading">
          <h1>{{ site.title }}</h1>
          {% if site.description %}
          <span class="subheading">{{ site.description }}</span>
          {% endif %}
        </div>
      </div>
    </div>
  </div>
</header>

<script>
(function() {
  var canvas = document.getElementById('voronoi-bg');
  if (!canvas || !canvas.getContext) { return; }
  var ctx = canvas.getContext('2d');
  if (!ctx) { return; }
  if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) { return; }
  var points = [];
  var numPoints = 40;
  var w, h;

  function resize() {
    var rect = canvas.parentElement.getBoundingClientRect();
    w = canvas.width = rect.width * window.devicePixelRatio;
    h = canvas.height = rect.height * window.devicePixelRatio;
    canvas.style.width = rect.width + 'px';
    canvas.style.height = rect.height + 'px';
    ctx.setTransform(window.devicePixelRatio, 0, 0, window.devicePixelRatio, 0, 0);
  }

  function initPoints() {
    points = [];
    for (var i = 0; i < numPoints; i++) {
      points.push({
        x: Math.random() * (w / window.devicePixelRatio),
        y: Math.random() * (h / window.devicePixelRatio),
        vx: (Math.random() - 0.5) * 0.3,
        vy: (Math.random() - 0.5) * 0.3
      });
    }
  }

  function movePoints() {
    var pw = w / window.devicePixelRatio;
    var ph = h / window.devicePixelRatio;
    for (var i = 0; i < points.length; i++) {
      var p = points[i];
      p.x += p.vx;
      p.y += p.vy;
      if (p.x < 0 || p.x > pw) p.vx *= -1;
      if (p.y < 0 || p.y > ph) p.vy *= -1;
    }
  }

  function drawVoronoi() {
    var pw = w / window.devicePixelRatio;
    var ph = h / window.devicePixelRatio;
    ctx.clearRect(0, 0, pw, ph);

    // Build grid of nearest point indices
    var step = 4;
    var cols = Math.ceil(pw / step) + 1;
    var rows = Math.ceil(ph / step) + 1;
    var grid = new Array(cols);

    for (var gxi = 0; gxi < cols; gxi++) {
      grid[gxi] = new Array(rows);
      var gx = gxi * step;
      for (var gyi = 0; gyi < rows; gyi++) {
        var gy = gyi * step;
        var minD = Infinity, minI = 0;
        for (var i = 0; i < points.length; i++) {
          var dx = gx - points[i].x, dy = gy - points[i].y;
          var d = dx * dx + dy * dy;
          if (d < minD) { minD = d; minI = i; }
        }
        grid[gxi][gyi] = minI;
      }
    }

    // Draw edge pixels as small rects for visible lines
    ctx.fillStyle = 'rgba(255, 255, 255, 0.18)';
    for (var gxi = 0; gxi < cols - 1; gxi++) {
      for (var gyi = 0; gyi < rows - 1; gyi++) {
        var c = grid[gxi][gyi];
        if (c !== grid[gxi + 1][gyi] || c !== grid[gxi][gyi + 1]) {
          ctx.fillRect(gxi * step, gyi * step, step, step);
        }
      }
    }

    // Draw seed points
    for (var i = 0; i < points.length; i++) {
      ctx.beginPath();
      ctx.arc(points[i].x, points[i].y, 2, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(255, 255, 255, 0.3)';
      ctx.fill();
    }
  }

  function animate() {
    movePoints();
    drawVoronoi();
    requestAnimationFrame(animate);
  }

  resize();
  initPoints();
  animate();
  window.addEventListener('resize', function() { resize(); initPoints(); });
})();
</script>

<div class="container space-grotesk">
  <div class="row">
    <div class="col-lg-8 col-md-10 mx-auto">
      <i>Personal blog to keep a tack of my work, experiments, findings and thoughts.</i>
      <a href="https://github.com/ikouchiha47" style="display:inline-block">Github</a> and 
      <a href="https://github.com/go-batteries" style="display:inline-block">Github</a>
    </div>
  </div>

  <p>&nbsp;</p>

  <div class="row">
    <div class="col-lg-8 col-md-10 mx-auto">

      {{ content }}

      <!-- Home Post List -->
      {% assign shown = 0 %}
      {% for post in site.posts %}
        {% if post.active != true or post.hidden == true %}
          {% continue %}
        {% endif %}
        {% if shown >= 5 %}
          {% break %}
        {% endif %}
        {% assign shown = shown | plus: 1 %}

      <article class="post-preview">
        <a href="{{ post.url | prepend: site.baseurl | replace: '//', '/' }}">
          <h2 class="post-title">{{ post.title }}</h2>
          {% if post.subtitle %}
          <h3 class="post-subtitle">{{ post.subtitle }}</h3>
          {% else %}
          <h3 class="post-subtitle">{{ post.excerpt | strip_html | truncatewords: 15 }}</h3>
          {% endif %}
        </a>
        <p class="post-meta">Posted by
          {% if post.author %}
          {{ post.author }}
          {% else %}
          {{ site.author }}
          {% endif %}
          on
          {{ post.date | date: '%B %d, %Y' }} &middot; {% include read_time.html content=post.content %}            
        </p>
      </article>

      <hr>

      {% endfor %}

      <!-- Pager -->
      <div class="clearfix">
        <a class="btn btn-primary float-right" href="{{"/posts" | relative_url }}">View All Posts &rarr;</a>
      </div>

    </div>
  </div>
</div>
