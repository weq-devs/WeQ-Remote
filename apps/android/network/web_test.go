package androidnet

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"tailscale.com/tsnet"
)

func TestReconnectCachesOnlyImmutableCodeAssets(t *testing.T) {
	var calls atomic.Int32
	token := strings.Repeat("d", 64)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		w.Header().Set("Content-Type", "text/javascript")
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		_, _ = io.WriteString(w, "synthetic static code")
	}))
	defer backend.Close()
	target, _ := url.Parse(backend.URL)
	connect := func(credential string) (*Client, string, string) {
		t.Helper()
		local := strings.Repeat("e", 64)
		transport := &http.Transport{DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, network, target.Host)
		}}
		client := &Client{http: &http.Client{Transport: transport}}
		origin, err := client.OpenWeb("http://100.64.0.10:7691", credential, local)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(client.Close)
		return client, origin, local
	}
	get := func(origin, local, path string) int {
		t.Helper()
		req, _ := http.NewRequest("GET", origin+path, nil)
		req.Header.Set("Cookie", "weq_remote_local="+local)
		response, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		body, _ := io.ReadAll(response.Body)
		if response.StatusCode == 200 && string(body) != "synthetic static code" {
			t.Fatal("body changed")
		}
		return response.StatusCode
	}
	first, origin, local := connect(token)
	if get(origin, local, "/assets/index-Abcd1234.js") != 200 {
		t.Fatal("asset unavailable")
	}
	first.Close()
	_, nextOrigin, nextLocal := connect(token)
	if get(nextOrigin, nextLocal, "/assets/index-Abcd1234.js") != 200 {
		t.Fatal("cached asset unavailable")
	}
	if calls.Load() != 1 {
		t.Fatalf("reconnect fetched immutable code again: %d", calls.Load())
	}
	if get(nextOrigin, "wrong", "/assets/index-Abcd1234.js") != 403 {
		t.Fatal("cache bypassed local authentication")
	}
	for _, path := range []string{"/trpc/probe", "/_media/pic", "/assets/nohash.js"} {
		get(nextOrigin, nextLocal, path)
		get(nextOrigin, nextLocal, path)
	}
	if calls.Load() != 7 {
		t.Fatal("business response entered static cache")
	}
	_, otherOrigin, otherLocal := connect(strings.Repeat("f", 64))
	get(otherOrigin, otherLocal, "/assets/index-Abcd1234.js")
	if calls.Load() != 8 {
		t.Fatal("cache crossed device authorization")
	}
}

func TestWebProxyIsConfinedAndAuthenticated(t *testing.T) {
	token, local := strings.Repeat("a", 64), strings.Repeat("b", 64)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+token || strings.Contains(r.Header.Get("Cookie"), local) || r.Host != "100.64.0.10:7691" {
			t.Error("credentials or destination not rewritten safely")
		}
		_, _ = io.WriteString(w, "Web fixture")
	}))
	defer backend.Close()
	target, _ := url.Parse(backend.URL)
	transport := &http.Transport{DialContext: func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, target.Host)
	}}
	client := &Client{server: &tsnet.Server{}, http: &http.Client{Transport: transport}}
	defer client.Close()
	if client.HasWeb() {
		t.Fatal("unopened client reports a Web proxy")
	}
	origin, err := client.OpenWeb("http://100.64.0.10:7691", token, local)
	if err != nil {
		t.Fatal(err)
	}
	if !client.HasWeb() {
		t.Fatal("open proxy was not retained")
	}
	browser := &http.Client{Timeout: 5 * time.Second}
	check := func(cookie, source string, code int) {
		t.Helper()
		request, _ := http.NewRequest("GET", origin+"/trpc/probe", nil)
		if cookie != "" {
			request.Header.Set("Cookie", "weq_remote_local="+cookie)
		}
		if source != "" {
			request.Header.Set("Origin", source)
		}
		response, err := browser.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		if response.StatusCode != code {
			t.Fatalf("unexpected status: %d", response.StatusCode)
		}
		if code == 200 {
			data, _ := io.ReadAll(response.Body)
			if string(data) != "Web fixture" {
				t.Fatal("response not forwarded")
			}
		}
	}
	check("", "", 403)
	check(strings.Repeat("c", 64), "", 403)
	check(local, "https://evil.invalid", 403)
	check(local, origin, 200)
	client.Close()
	if client.HasWeb() {
		t.Fatal("closed client reports a live Web proxy")
	}
	if _, err := browser.Get(origin); err == nil {
		t.Fatal("closed network left a listening Web gateway")
	}
}
