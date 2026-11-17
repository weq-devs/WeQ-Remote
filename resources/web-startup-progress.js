(function () {
  if (window.__weqResourceProgress) return;
  window.__weqResourceProgress = true;
  var sizes = new Map(), finished = new Set(), observer, mutations, timer, stopped = false, last = '';
  function codeURL(value) {
    try {
      var url = new URL(value, location.href);
      return url.origin === location.origin && /^\/assets\/[^/]+\.(js|css)$/.test(url.pathname) ? url.pathname + url.search : null;
    } catch (_) { return null; }
  }
  function entries(values) {
    values.forEach(function (entry) {
      var path = codeURL(entry.name);
      // 失败请求也可能产生 timing 条目，不能将零字节失败算成下载完成。
      if (path && !(entry.responseStatus >= 400) &&
          (entry.encodedBodySize > 0 || entry.decodedBodySize > 0 || entry.responseStatus >= 200)) finished.add(path);
    });
  }
  function report() {
    timer = null;
    if (stopped) return;
    if (!sizes.size) {
      var meta = document.querySelector('meta[name="weq-startup-resources"]');
      if (meta) try {
        var data = JSON.parse(meta.content);
        if (data.version === 1 && Array.isArray(data.resources) && data.resources.length <= 4096)
          data.resources.forEach(function (asset) {
            var path = codeURL(asset.path);
            if (path && Number.isSafeInteger(asset.size) && asset.size > 0 && asset.size <= 536870912) sizes.set(path, asset.size);
          });
      } catch (_) {}
    }
    entries(performance.getEntriesByType('resource'));
    var loads = window.weqRemoteResourceLoads;
    if (loads) Object.keys(loads).forEach(function (path) {
      if (loads[path] === true) finished.add(path);
      else if (loads[path] === false) finished.delete(path);
    });
    if (!sizes.size) return;
    var completed = 0, loadedBytes = 0, totalBytes = 0;
    sizes.forEach(function (size, path) {
      totalBytes += size;
      if (finished.has(path)) { completed++; loadedBytes += size; }
    });
    var value = { completed: completed, total: sizes.size, loadedBytes: loadedBytes, totalBytes: totalBytes };
    var text = JSON.stringify(value);
    if (text === last) return;
    last = text;
    try {
      if (window.webkit && window.webkit.messageHandlers.weqResources) window.webkit.messageHandlers.weqResources.postMessage(value);
      else if (window.weqRemoteLinks) window.weqRemoteLinks.resources(text);
    } catch (_) {}
  }
  function schedule() { if (!stopped && !timer) timer = setTimeout(report, 100); }
  function stop() {
    var state = window.weqRemoteStartup;
    if (!state || state.state === 'loading') return;
    clearTimeout(timer);
    report();
    stopped = true;
    if (observer) observer.disconnect();
    if (mutations) mutations.disconnect();
    document.removeEventListener('readystatechange', schedule);
    window.removeEventListener('weq-remote-resource-load', schedule);
    window.removeEventListener('weq-remote-startup', stop);
  }
  if (typeof PerformanceObserver !== 'undefined') {
    observer = new PerformanceObserver(function (list) { entries(list.getEntries()); schedule(); });
    try { observer.observe({ type: 'resource', buffered: true }); }
    catch (_) { observer.observe({ entryTypes: ['resource'] }); }
  }
  // iOS 在文档开始注入，Android 在首帧提交时注入；两端均补读早到资源。
  mutations = new MutationObserver(schedule);
  mutations.observe(document, { childList: true, subtree: true });
  document.addEventListener('readystatechange', schedule);
  window.addEventListener('weq-remote-startup', stop);
  window.addEventListener('weq-remote-resource-load', schedule);
  report();
  stop();
})();
