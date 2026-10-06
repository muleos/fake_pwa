/**
 * WebChromeScript.ets
 * 注入到每个页面 document-start 的 JS：
 * 沉浸式取色探针：采样页面顶部/底部背景色，经 console 上报给原生（__STQ_CHROME__）
 * 参考实现：aira-browser HostedWebNode 页面主题探针
 */

export const WEB_CHROME_SCRIPT: string = `
;(function () {
  if (window.__stqChromeInstalled) { return; }
  window.__stqChromeInstalled = 1;

  /* ---------------- 取色探针 ---------------- */
  var lastBg = '';
  var lastBbg = '';

  function toHex(value) {
    var normalized = String(value || '').trim();
    if (!normalized) { return ''; }
    var probe = document.createElement('span');
    probe.style.color = '';
    probe.style.color = normalized;
    if (!probe.style.color) { return ''; }
    (document.body || document.documentElement).appendChild(probe);
    var resolved = window.getComputedStyle(probe).color || '';
    probe.remove();
    var match = resolved.match(/rgba?\\(([^)]+)\\)/i);
    if (!match) { return ''; }
    var parts = match[1].split(',');
    var alpha = parts.length > 3 ? parseFloat(parts[3]) : 1;
    if (alpha < 0.5) { return ''; }
    function ch(x) {
      var n = parseInt(x, 10);
      if (isNaN(n)) { return 0; }
      return Math.max(0, Math.min(255, n));
    }
    function hx(x) {
      var s = ch(x).toString(16);
      return s.length < 2 ? '0' + s : s;
    }
    return '#' + hx(parts[0]) + hx(parts[1]) + hx(parts[2]);
  }

  function cssAlpha(color) {
    var m = String(color || '').match(/rgba?\\(([^)]+)\\)/i);
    if (!m) { return 1; }
    var parts = m[1].split(',');
    return parts.length > 3 ? parseFloat(parts[3]) : 1;
  }

  function sampleTopBackground() {
    try {
      var metas = document.querySelectorAll('meta[name="theme-color"]');
      for (var i = metas.length - 1; i >= 0; i--) {
        var content = metas[i].getAttribute('content') || '';
        var mm = content.match(/#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\\b/);
        if (mm) {
          var mc = toHex(mm[0]);
          if (mc) { return mc; }
        }
      }
      var vw = Math.max(document.documentElement.clientWidth || 0, window.innerWidth || 1);
      var stack = document.elementsFromPoint ? document.elementsFromPoint(vw / 2, 10) : [];
      var candidates = stack.slice(0, 8);
      candidates.push(document.body, document.documentElement);
      for (var j = 0; j < candidates.length; j++) {
        var el = candidates[j];
        var hops = 0;
        while (el && hops < 6) {
          var cs = window.getComputedStyle(el);
          var bg = cs.backgroundColor;
          if (bg && cssAlpha(bg) >= 0.5) {
            var resolved = toHex(bg);
            if (resolved) { return resolved; }
          }
          el = el.parentElement;
          hops++;
        }
      }
    } catch (e) { }
    return '';
  }

  function sampleBottomBackground() {
    try {
      var vw = Math.max(document.documentElement.clientWidth || 0, window.innerWidth || 1);
      var vh = Math.max(document.documentElement.clientHeight || 0, window.innerHeight || 1);
      var stack = document.elementsFromPoint ? document.elementsFromPoint(vw / 2, vh - 10) : [];
      var candidates = stack.slice(0, 8);
      candidates.push(document.body, document.documentElement);
      for (var j = 0; j < candidates.length; j++) {
        var el = candidates[j];
        var hops = 0;
        while (el && hops < 6) {
          var cs = window.getComputedStyle(el);
          var bg = cs.backgroundColor;
          if (bg && cssAlpha(bg) >= 0.5) {
            var resolved = toHex(bg);
            if (resolved) { return resolved; }
          }
          el = el.parentElement;
          hops++;
        }
      }
    } catch (e) { }
    return '';
  }

  function sendTheme() {
    try {
      var bg = sampleTopBackground();
      var bbg = sampleBottomBackground();
      if ((!bg || bg === lastBg) && (!bbg || bbg === lastBbg)) { return; }
      if (bg && bg !== lastBg) { lastBg = bg; }
      if (bbg && bbg !== lastBbg) { lastBbg = bbg; }
      console.info('__STQ_CHROME__' + JSON.stringify({ bg: bg, bbg: bbg }));
    } catch (e) { }
  }

  var themeTimer = null;
  function scheduleTheme() {
    if (themeTimer) { return; }
    themeTimer = setTimeout(function () { themeTimer = null; sendTheme(); }, 300);
  }


  /* ---------------- 安装观察器 ---------------- */
  try {
    new MutationObserver(scheduleTheme).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode', 'data-color-scheme']
    });
  } catch (e) { }
  try {
    new MutationObserver(scheduleTheme).observe(document.head, { childList: true, subtree: true });
  } catch (e) { }

  function installBodyObservers() {
    if (!document.body) { return; }
    try {
      new MutationObserver(scheduleTheme).observe(document.body, {
        childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style']
      });
    } catch (e) { }
  }

  if (document.body) {
    installBodyObservers();
  } else {
    document.addEventListener('DOMContentLoaded', function () {
      installBodyObservers();
      scheduleTheme();
    }, { once: true });
  }

  window.addEventListener('load', function () { scheduleTheme(); });
  window.addEventListener('pageshow', function () { scheduleTheme(); });
  // 页面不可见时跳过采样，降低后台 CPU/电量开销
  setInterval(function () { if (!document.hidden) { scheduleTheme(); } }, 2000);
  scheduleTheme();
  /* 暴露给原生：详情浮层关闭后主动重报底层页面主题色 */
  window.__stqScheduleTheme = scheduleTheme;
})();
;(function () {
  /* ---------------- 详情浮层桥（SPA 路由拦截） ----------------
   * 站点（soutushenqi.com）是 Vue Router SPA，图片卡片点击走
   *   isMobile()（window.screen.width<=768，手机上恒 true）? router.push(详情URL) : window.open(详情URL)
   * 手机上走 pushState 客户端路由——不产生主文档加载，壳的 onLoadIntercept 详情浮层
   * 根本不会触发，详情只能在主 WebView 内渲染；返回首页时列表页组件被重建
   * （重新请求 + 滚动丢失），表现就是"首页重新加载"。
   * 修复：在 history.pushState 处把"进入详情页"的导航截下来，改由壳的浮层承载——
   *   ① 主 WebView 停在列表页不动（组件不卸载、滚动不丢、零重新请求）；
   *   ② 详情 URL 经 console 上报原生（__STQ_DETAIL__），由浮层 Web 加载；
   *   ③ 详情页依赖 opener 写在 sessionStorage[key] 里的列表数据，而 sessionStorage
   *      不跨 Web 实例，故先镜像到 localStorage（同源共享），浮层 document-start 再还原。
   * 参考实现：TapTapWeb 壳把 window.open 改写为壳内导航的同源兜底思路。
   */
  if ((location.hostname || '').indexOf('soutushenqi') < 0) { return; }
  if (window.__stqDetailBridgeInstalled) { return; }
  window.__stqDetailBridgeInstalled = 1;

  var STQ_MIRROR_PREFIX = '__stq_sess_';
  var STQ_SENTINEL = 'stq-detail-intercepted';

  function stqAbs(u) {
    try {
      var s = String(u || '');
      if (!s) { return ''; }
      return new URL(s, location.href).href;
    } catch (e) { return ''; }
  }

  function stqIsDetail(u) {
    try {
      return (new URL(u, location.href).pathname || '').indexOf('/detail') >= 0;
    } catch (e) { return false; }
  }

  /* 当前文档自己就在详情页（浮层内的翻图）时不拦截，让站点在浮层内自由路由 */
  function stqCurIsDetail() {
    return (location.pathname || '').indexOf('/detail') >= 0;
  }

  function stqKeyOf(u) {
    try { return new URL(u, location.href).searchParams.get('key') || ''; } catch (e) { return ''; }
  }

  /* 把 opener 写在 sessionStorage[key] 的列表数据镜像到 localStorage，供浮层还原 */
  function stqMirrorSession(u) {
    try {
      var k = stqKeyOf(u);
      if (!k) { return; }
      var v = sessionStorage.getItem(k);
      if (v) { localStorage.setItem(STQ_MIRROR_PREFIX + k, v); }
    } catch (e) { }
  }

  function stqReport(u) {
    try { console.info('__STQ_DETAIL__' + u); } catch (e) { }
  }

  /* 浮层侧还原：sessionStorage 缺失时从 localStorage 镜像补回；
   * 都没有则写入空列表占位——详情页对该键做 JSON.parse，缺键会抛错整页白屏 */
  function stqRestoreSession() {
    try {
      if (!stqCurIsDetail()) { return; }
      var k = stqKeyOf(location.href);
      if (!k || sessionStorage.getItem(k)) { return; }
      var v = localStorage.getItem(STQ_MIRROR_PREFIX + k);
      if (v) {
        sessionStorage.setItem(k, v);
        localStorage.removeItem(STQ_MIRROR_PREFIX + k);
      } else {
        sessionStorage.setItem(k, '{"list":[]}');
      }
    } catch (e) { }
  }

  /* 命中详情导航：上报原生并返回 true（调用方据此中断本次路由提交） */
  function stqHit(u) {
    var a = stqAbs(u);
    if (!a || !stqIsDetail(a) || stqCurIsDetail()) { return false; }
    stqMirrorSession(a);
    stqReport(a);
    return true;
  }

  stqRestoreSession();

  var stqOrigPush = history.pushState;
  var stqOrigReplace = history.replaceState;
  /* 抛哨兵异常中断 Vue Router 提交：其 currentRoute 赋值在 history push 之后，
   * 抛错即中止，内部路由状态与 DOM 都留在列表页（站点未监听 unhandledrejection） */
  try {
    history.pushState = function (state, title, url) {
      if (arguments.length >= 3 && stqHit(url)) { throw new Error(STQ_SENTINEL); }
      return stqOrigPush.apply(history, arguments);
    };
  } catch (e) { }
  try {
    history.replaceState = function (state, title, url) {
      if (arguments.length >= 3 && stqHit(url)) { throw new Error(STQ_SENTINEL); }
      return stqOrigReplace.apply(history, arguments);
    };
  } catch (e) { }
  /* 哨兵异常已被本桥消化：吞掉对应的 unhandledrejection，避免控制台/站点误报 */
  try {
    window.addEventListener('unhandledrejection', function (e) {
      var r = e && e.reason;
      var msg = ((r && (r.message || r)) || '') + '';
      if (msg.indexOf(STQ_SENTINEL) >= 0) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    }, true);
  } catch (e) { }

  /* 兜底 A：window.open（电脑 UA / 大屏时站点走这条）→ 详情交给浮层，不再新开窗口 */
  try {
    var stqOrigOpen = window.open;
    window.open = function (u) {
      if (stqHit(u)) { return null; }
      return stqOrigOpen.apply(window, arguments);
    };
  } catch (e) { }

  /* 兜底 B：锚点直跳详情（站点改版成 <a href> 时） */
  document.addEventListener('click', function (e) {
    try {
      var el = e.target;
      while (el && el !== document.documentElement) {
        if (el.tagName === 'A' && el.getAttribute('href')) {
          var a = stqAbs(el.getAttribute('href'));
          if (a && stqIsDetail(a) && !stqCurIsDetail()) {
            stqMirrorSession(a);
            stqReport(a);
            e.preventDefault();
            e.stopPropagation();
          }
          return;
        }
        el = el.parentElement;
      }
    } catch (err) { }
  }, true);
})();

;(function () {
  /* 图片保存兜底桥：原生直取被源站拒绝（防盗链/TLS 指纹）时，改在页面上下文内 fetch
   * ——与 <img> 同一 Cookie/UA/凭证上下文，同源图与带 CORS 头的跨域图均可取回。
   * 结果转 base64 分片经 console 回传：__STQ_IMGB64__<reqId>:<seq|meta|err>:<total>:<chunk>
   * （base64 字符集不含 ':'，分片解析安全；原生侧拼装后写图库。） */
  if (window.__stqImgBridgeInstalled) { return; }
  window.__stqImgBridgeInstalled = 1;
  window.__stqFetchImage = function (reqId, url) {
    var CHUNK = 32768;
    function report(s) { try { console.info(s); } catch (e) { } }
    function fail(m) { report('__STQ_IMGB64__' + reqId + ':err:' + m); }
    try {
      fetch(url, { credentials: 'include', referrerPolicy: 'no-referrer-when-downgrade' })
        .then(function (r) {
          if (!r.ok) { throw new Error('HTTP ' + r.status); }
          return r.blob();
        })
        .then(function (b) {
          var fr = new FileReader();
          fr.onload = function () {
            try {
              var dataUrl = String(fr.result || '');
              var comma = dataUrl.indexOf(',');
              var b64 = comma >= 0 ? dataUrl.substring(comma + 1) : '';
              if (!b64) { fail('empty'); return; }
              var total = Math.ceil(b64.length / CHUNK);
              report('__STQ_IMGB64__' + reqId + ':meta:' + total + ':' + b64.length);
              for (var i = 0; i < total; i++) {
                report('__STQ_IMGB64__' + reqId + ':' + i + ':' + total + ':'
                  + b64.substring(i * CHUNK, (i + 1) * CHUNK));
              }
            } catch (e) { fail(e && e.message ? e.message : 'read'); }
          };
          fr.onerror = function () { fail('fileReader'); };
          fr.readAsDataURL(b);
        })
        .catch(function (e) { fail(e && e.message ? e.message : 'fetch'); });
    } catch (e) {
      fail(e && e.message ? e.message : 'throw');
    }
  };
})();
//# sourceURL=stq-web-chrome.js
`;
