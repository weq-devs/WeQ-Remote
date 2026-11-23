(function (report) {
    if (window.__weqMenuObserved) return;
    window.__weqMenuObserved = true;
    var frame = 0;
    var active = null;
    var ready = false;
    var selector = 'button.weq-remote-shell-menu';
    var observer = new MutationObserver(schedule);
    function publish(value) {
        if (value === ready) return;
        ready = value;
        report(value);
    }
    function watchUntilReady() {
        observer.observe(document.documentElement, {
            subtree: true, childList: true, attributes: true,
            attributeFilter: ['class', 'style', 'disabled', 'hidden', 'inert', 'aria-hidden', 'data-weq-layout'],
        });
        window.addEventListener('resize', schedule);
        window.addEventListener('load', schedule);
    }
    function follow(button) {
        active = button;
        observer.disconnect();
        window.removeEventListener('resize', schedule);
        window.removeEventListener('load', schedule);
        // 接手后只跟踪入口退出 DOM，不响应聊天列表更新或详情页临时隐藏顶栏。
        for (var parent = button.parentElement; parent; parent = parent.parentElement)
            observer.observe(parent, {childList: true});
    }
    function check() {
        frame = 0;
        var buttons = document.querySelectorAll(selector);
        for (var button of buttons) {
            if (typeof window.weqRemoteShell?.openMenu !== 'function') break;
            if (button.disabled || button.closest('[inert], [aria-hidden="true"]')) continue;
            var rect = button.getBoundingClientRect();
            if (!rect.width || !rect.height) continue;
            var hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
            if (!button.contains(hit)) continue;
            var ancestor = button;
            while (ancestor && getComputedStyle(ancestor).opacity !== '0') ancestor = ancestor.parentElement;
            if (ancestor) continue;
            follow(button);
            publish(true);
            return;
        }
        if (ready && buttons.length) { follow(buttons[0]); return; }
        if (active) {
            active = null;
            observer.disconnect();
            watchUntilReady();
        }
        publish(false);
    }
    function schedule() {
        if (!active?.isConnected && !frame) frame = requestAnimationFrame(check);
    }
    watchUntilReady();
    schedule();
})
