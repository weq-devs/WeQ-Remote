package webgateway

import (
	"crypto/subtle"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Gateway struct {
	server           *http.Server
	listener         net.Listener
	origin           string
	secret           string
	token            string
	mu               sync.Mutex
	connections      map[net.Conn]struct{}
	closed           bool
	base             *http.Transport
	proxy            *httputil.ReverseProxy
	target           *url.URL
	assets           *http.Transport
	releases         string
	currentRelease   atomic.Value
	routeDone        chan struct{}
	releaseMu        sync.Mutex
	lastReleaseRoute chan struct{}
	lastReleaseCheck time.Time
}

func Open(token, secret string) (*Gateway, error) {
	if !Credential(token) || !Credential(secret) {
		return nil, errors.New("invalid web credential")
	}
	listener, err := listenWebOrigin(token)
	if err != nil {
		return nil, errors.New("网页本地端口不可用，请稍后重新连接")
	}
	g := &Gateway{listener: listener, origin: "http://" + listener.Addr().String(), secret: secret,
		token: token, connections: make(map[net.Conn]struct{}), releases: releaseDirectory(token)}
	g.currentRelease.Store(readRelease(g.releases))
	g.server = &http.Server{ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second,
		ConnState: func(conn net.Conn, state http.ConnState) {
			g.mu.Lock()
			defer g.mu.Unlock()
			if state == http.StateNew {
				g.connections[conn] = struct{}{}
			}
			if state == http.StateClosed {
				delete(g.connections, conn)
			}
		}, Handler: http.HandlerFunc(g.serve)}
	go func() { _ = g.server.Serve(listener) }()
	return g, nil
}

func Credential(value string) bool {
	return len(value) == 64 && strings.Trim(value, "0123456789abcdef") == ""
}

func (g *Gateway) Origin() string { return g.origin }

func (g *Gateway) Close() {
	g.mu.Lock()
	g.closed = true
	g.detachLocked()
	for conn := range g.connections {
		_ = conn.Close()
	}
	g.mu.Unlock()
	_ = g.listener.Close()
	_ = g.server.Close()
}

func (g *Gateway) detachLocked() {
	if g.routeDone == nil {
		return
	}
	close(g.routeDone)
	g.routeDone = nil
	g.proxy = nil
	g.target = nil
	if g.assets != nil {
		g.assets.CloseIdleConnections()
		g.assets = nil
	}
	for conn := range g.connections {
		_ = conn.Close()
	}
}

func (g *Gateway) Attach(target *url.URL, transport http.RoundTripper) {
	g.mu.Lock()
	defer g.mu.Unlock()
	base, _ := transport.(*http.Transport)
	if g.closed || (base != nil && base == g.base && g.target != nil && target.String() == g.target.String()) {
		return
	}
	g.detachLocked()
	g.routeDone = make(chan struct{})
	g.base = base
	if base != nil {
		g.assets = base.Clone()
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = cachedWebTransport(transport, g.token)
	proxy.ModifyResponse = func(response *http.Response) error {
		g.secure(response.Header)
		return nil
	}
	director := proxy.Director
	proxy.Director = func(r *http.Request) {
		director(r)
		r.Host = target.Host
		r.Header.Set("Authorization", "Bearer "+g.token)
		for _, name := range []string{"Origin", "Referer", "X-Forwarded-For", "Forwarded", "Proxy-Authorization"} {
			r.Header.Del(name)
		}
		var cookies []string
		for _, cookie := range r.Cookies() {
			if cookie.Name != "weq_remote_local" && cookie.Name != releaseCookie {
				cookies = append(cookies, cookie.String())
			}
		}
		r.Header.Set("Cookie", strings.Join(cookies, "; "))
	}
	proxy.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, _ error) {
		http.Error(w, "WeQ connection unavailable", http.StatusBadGateway)
	}
	g.proxy = proxy
	g.target = target
	go g.refreshRelease(target, g.assets, g.routeDone, true)
}

func (g *Gateway) secure(header http.Header) {
	header.Set("Content-Security-Policy", "default-src 'self' blob: data:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' "+strings.Replace(g.origin, "http:", "ws:", 1)+"; frame-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
	header.Set("Referrer-Policy", "no-referrer")
}

func (g *Gateway) serve(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie("weq_remote_local")
	if r.Host != g.listener.Addr().String() || err != nil || subtle.ConstantTimeCompare([]byte(cookie.Value), []byte(g.secret)) != 1 || (r.Header.Get("Origin") != "" && r.Header.Get("Origin") != g.origin) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	g.mu.Lock()
	proxy := g.proxy
	g.mu.Unlock()
	// Dev HMR query variants must reach the running Vite server.
	if (proxy == nil || r.URL.RawQuery == "" || r.URL.Path == "/" || r.URL.Path == updatePath) && g.serveRelease(w, r) {
		return
	}
	if proxy != nil {
		proxy.ServeHTTP(w, r)
		return
	}
	// 已访问过的其余哈希分包也可在断网时按原 URL 读取。
	if r.Method == http.MethodGet && hashedWebCode.MatchString(r.URL.Path) {
		response, err := cachedWebTransport(offlineTransport{}, g.token).RoundTrip(r)
		if err == nil {
			defer response.Body.Close()
			g.secure(w.Header())
			for key, values := range response.Header {
				for _, value := range values {
					w.Header().Add(key, value)
				}
			}
			w.WriteHeader(response.StatusCode)
			_, _ = io.Copy(w, response.Body)
			return
		}
	}
	http.Error(w, "WeQ connection unavailable", http.StatusServiceUnavailable)
}

type offlineTransport struct{}

func (offlineTransport) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("offline")
}
