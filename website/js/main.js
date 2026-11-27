// MoMa landing page: theme toggle, banknote guilloche patterns, scroll reveal, latest release link.
(function () {
  'use strict';

  var root = document.documentElement;
  root.classList.add('js');

  // ---------- Theme ----------
  var media = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  function currentTheme() {
    var t = root.getAttribute('data-theme');
    if (t === 'light' || t === 'dark') return t;
    return media && media.matches ? 'dark' : 'light';
  }
  var toggle = document.getElementById('theme-toggle');
  if (toggle) {
    toggle.addEventListener('click', function () {
      var next = currentTheme() === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      try {
        localStorage.setItem('moma-theme', next);
      } catch (e) {
        /* storage unavailable: the choice lasts for this page view */
      }
    });
  }

  // ---------- Guilloche (rosette like the engraving on banknotes) ----------
  var SVG = 'http://www.w3.org/2000/svg';
  function rosette(R, r, d, turns, steps) {
    // Hypotrochoid: the classic spirograph curve used for guilloche engraving.
    var pts = [];
    var n = steps;
    for (var i = 0; i <= n; i++) {
      var t = (i / n) * Math.PI * 2 * turns;
      var x = (R - r) * Math.cos(t) + d * Math.cos(((R - r) / r) * t);
      var y = (R - r) * Math.sin(t) - d * Math.sin(((R - r) / r) * t);
      pts.push((x + 380).toFixed(1) + ' ' + (y + 380).toFixed(1));
    }
    return 'M' + pts.join('L') + 'Z';
  }
  function guilloche(el, seed) {
    var svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('viewBox', '0 0 760 760');
    svg.setAttribute('focusable', 'false');
    var specs = [
      [300, 41, 120, 41, 2400],
      [260, 37, 96, 37, 2200],
      [210, 29, 70, 29, 1800],
      [150, 23, 46, 23, 1400]
    ];
    specs.forEach(function (s) {
      var p = document.createElementNS(SVG, 'path');
      p.setAttribute('d', rosette(s[0], s[1], s[2], s[3], s[4]));
      svg.appendChild(p);
    });
    var right = seed % 2 === 0;
    svg.style[right ? 'right' : 'left'] = '-220px';
    svg.style.top = seed === 0 ? '-200px' : '-120px';
    el.appendChild(svg);
  }
  var patterns = document.querySelectorAll('[data-guilloche]');
  for (var i = 0; i < patterns.length; i++) guilloche(patterns[i], i);

  // ---------- Reveal on scroll ----------
  var items = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (e) {
          if (e.isIntersecting) {
            e.target.classList.add('in');
            io.unobserve(e.target);
          }
        });
      },
      { rootMargin: '0px 0px -8% 0px', threshold: 0.08 }
    );
    for (var j = 0; j < items.length; j++) io.observe(items[j]);
  } else {
    for (var k = 0; k < items.length; k++) items[k].classList.add('in');
  }

  // ---------- Latest release: version label and direct APK link ----------
  // Optional nicety; the buttons already point to the releases page if this fails (offline, rate limit).
  if (window.fetch) {
    fetch('https://api.github.com/repos/NhanSamLe/money-manage-app/releases/latest', {
      headers: { Accept: 'application/vnd.github+json' }
    })
      .then(function (r) {
        return r.ok ? r.json() : null;
      })
      .then(function (rel) {
        if (!rel || !rel.tag_name) return;
        var version = String(rel.tag_name).replace(/^v/, '').split('+')[0];
        var labels = document.querySelectorAll('[data-version]');
        for (var a = 0; a < labels.length; a++) labels[a].textContent = 'phiên bản ' + version;
        var apk = (rel.assets || []).filter(function (x) {
          return /\.apk$/i.test(x.name);
        })[0];
        if (apk && /^https:\/\/github\.com\//.test(apk.browser_download_url)) {
          var links = document.querySelectorAll('[data-download]');
          for (var b = 0; b < links.length; b++) links[b].href = apk.browser_download_url;
        }
      })
      .catch(function () {
        /* keep the releases page link */
      });
  }
})();
