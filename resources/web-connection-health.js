(function () {
    if (window.__weqConnectionHealth) return;
    window.__weqConnectionHealth = true;
    var last = -Infinity;
    function sameComputer(value) {
        try {
            var url = new URL(value, location.href);
            var protocol = url.protocol.replace('ws:', 'http:').replace('wss:', 'https:');
            return protocol + '//' + url.host === location.origin;
        } catch (error) { return false; }
    }
    function failed() {
        var now = performance.now();
        if (now - last < 1000) return;
        last = now;
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.weqConnection)
            window.webkit.messageHandlers.weqConnection.postMessage('failed');
        else if (window.weqRemoteLinks) window.weqRemoteLinks.connectionFailed();
    }
    var fetch = window.fetch;
    window.fetch = function (input, options) {
        var local = sameComputer(typeof input === 'string' || input instanceof URL ? input : input && input.url);
        return fetch.apply(this, arguments).catch(function (error) {
            if (local && (!error || error.name !== 'AbortError')) failed();
            throw error;
        });
    };
    var Socket = window.WebSocket;
    window.WebSocket = class extends Socket {
        constructor(url, protocols) {
            super(...arguments);
            if (sameComputer(url)) {
                this.addEventListener('error', failed);
                this.addEventListener('close', function (event) { if (!event.wasClean) failed(); });
            }
        }
    };
})();
