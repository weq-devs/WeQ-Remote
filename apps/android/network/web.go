package androidnet

import (
	"crypto/subtle"
	"errors"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"time"
)

type webProxy struct {
	server      *http.Server
	listener    net.Listener
	mu          sync.Mutex
	connections map[net.Conn]struct{}
}

func (p *webProxy) close() {
	// Serve 可能尚未启动，不能只依赖 Server 关闭已登记的 listener。
	_ = p.listener.Close()
	_ = p.server.Close()
	p.mu.Lock()
	defer p.mu.Unlock()
	for connection := range p.connections {
		_ = connection.Close()
	}
}

func hexCredential(value string) bool {
	return len(value) == 64 && strings.Trim(value, "0123456789abcdef") == ""
}

func (c *Client) CloseWeb() {
	if c.routes != nil {
		c.routes.closeWeb()
		return
	}
	c.mu.Lock()
	web := c.web
	c.web = nil
	c.mu.Unlock()
	if web != nil {
		web.close()
	}
}

// HasWeb reports whether the current route still owns the WebView's local proxy.
func (c *Client) HasWeb() bool {
	if c.routes != nil {
		c.routes.mu.Lock()
		defer c.routes.mu.Unlock()
		return !c.routes.closed && c.routes.active != nil && c.routes.active.HasWeb()
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.web != nil
}

// OpenWeb 为 WebView 提供受限本机入口；所有 HTTP/WS 请求经内嵌 TS，不使用系统 VPN。
func (c *Client) OpenWeb(endpoint, token, localSecret string) (string, error) {
	if c.routes != nil {
		return c.routes.openWeb(endpoint, token, localSecret)
	}
	if !c.accepts(endpoint) || !hexCredential(token) || !hexCredential(localSecret) {
		return "", errors.New("invalid web destination or credential")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.http == nil {
		return "", errors.New("network closed")
	}
	if c.web != nil {
		return "", errors.New("web view already open")
	}
	target, _ := url.Parse(endpoint)
	listener, err := listenWebOrigin(token)
	if err != nil {
		return "", errors.New("网页本地端口不可用，请稍后重新连接")
	}
	origin := "http://" + listener.Addr().String()
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = cachedWebTransport(c.http.Transport, endpoint, token)
	proxy.ModifyResponse = func(response *http.Response) error {
		response.Header.Set("Content-Security-Policy", "default-src 'self' blob: data:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' "+strings.Replace(origin, "http:", "ws:", 1)+"; frame-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
		return nil
	}
	director := proxy.Director
	proxy.Director = func(r *http.Request) {
		director(r)
		r.Host = target.Host
		r.Header.Set("Authorization", "Bearer "+token)
		r.Header.Del("Origin")
		r.Header.Del("Referer")
		r.Header.Del("X-Forwarded-For")
		r.Header.Del("Forwarded")
		r.Header.Del("Proxy-Authorization")
		var cookies []string
		for _, cookie := range r.Cookies() {
			if cookie.Name != "weq_remote_local" {
				cookies = append(cookies, cookie.String())
			}
		}
		r.Header.Set("Cookie", strings.Join(cookies, "; "))
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) {
		http.Error(w, "WeQ connection unavailable", http.StatusBadGateway)
	}
	p := &webProxy{listener: listener, connections: make(map[net.Conn]struct{})}
	p.server = &http.Server{ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second,
		ConnState: func(conn net.Conn, state http.ConnState) {
			p.mu.Lock()
			defer p.mu.Unlock()
			if state == http.StateNew {
				p.connections[conn] = struct{}{}
			}
			if state == http.StateClosed {
				delete(p.connections, conn)
			}
		},
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			cookie, err := r.Cookie("weq_remote_local")
			if r.Host != listener.Addr().String() || err != nil || subtle.ConstantTimeCompare([]byte(cookie.Value), []byte(localSecret)) != 1 || (r.Header.Get("Origin") != "" && r.Header.Get("Origin") != origin) {
				http.Error(w, "forbidden", http.StatusForbidden)
				return
			}
			proxy.ServeHTTP(w, r)
		}),
	}
	c.web = p
	go func() { _ = p.server.Serve(listener) }()
	return origin, nil
}
