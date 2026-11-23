package webgateway

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestReleaseStartsOfflineAndSwitchesOnlyAfterCompleteUpdate(t *testing.T) {
	if err := SetWebCacheDirectory(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if err := SetWebStorageDirectory(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ClearWebCache()
		sharedWebAssets.Lock()
		sharedWebAssets.directory = ""
		sharedWebAssets.Unlock()
		webStorage.Lock()
		webStorage.directory = ""
		webStorage.Unlock()
	})

	token, secret := strings.Repeat("a", 64), strings.Repeat("b", 64)
	var version, sharedDownloads atomic.Int32
	version.Store(1)
	var breakUpdate atomic.Bool
	updateRequested := make(chan struct{}, 1)
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+token {
			t.Error("missing upstream authorization")
		}
		switch r.URL.Path {
		case "/":
			w.Header().Set("Content-Type", "text/html")
			fmt.Fprintf(w, `<html><head>%s<meta name="weq-startup-resources" content='{"version":1,"resources":[{"path":"/assets/shared-A1234567.js"},{"path":"/assets/entry-A123456%d.js"}]}'></head><body>version %d</body></html>`, offlineMarker, version.Load(), version.Load())
		case "/assets/shared-A1234567.js", "/assets/entry-A1234561.js", "/startup-theme.js":
			if r.URL.Path == "/assets/shared-A1234567.js" {
				sharedDownloads.Add(1)
			}
			w.Header().Set("Content-Type", "text/javascript")
			fmt.Fprintln(w, "/* cached code */")
		case "/assets/entry-A1234562.js":
			if breakUpdate.Load() {
				w.WriteHeader(503)
				updateRequested <- struct{}{}
				return
			}
			w.Header().Set("Content-Type", "text/javascript")
			fmt.Fprintln(w, "/* updated code */")
		case "/trpc/read":
			fmt.Fprintln(w, "live data")
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()
	target, _ := url.Parse(upstream.URL)

	open := func() *Gateway {
		t.Helper()
		g, err := Open(token, secret)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(g.Close)
		return g
	}
	wait := func(match func() bool) {
		t.Helper()
		deadline := time.Now().Add(4 * time.Second)
		for time.Now().Before(deadline) {
			if match() {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatal("release did not reach expected state")
	}
	get := func(g *Gateway, path, cookie string) (int, string) {
		t.Helper()
		req, _ := http.NewRequest("GET", g.Origin()+path, nil)
		req.AddCookie(&http.Cookie{Name: "weq_remote_local", Value: cookie})
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, err := io.ReadAll(res.Body)
		if err != nil {
			t.Fatal(err)
		}
		return res.StatusCode, string(body)
	}

	first := open()
	first.Attach(target, &http.Transport{})
	wait(first.HasRelease)
	first.Close()
	next := open()
	if next.Origin() != first.Origin() {
		t.Fatal("web origin changed after restart")
	}
	if code, _ := get(next, "/", strings.Repeat("c", 64)); code != 403 {
		t.Fatal("cached shell lacked local authentication")
	}
	if code, html := get(next, "/", secret); code != 200 || !strings.Contains(html, "version 1") {
		t.Fatalf("offline shell: %d %q", code, html)
	}
	if code, _ := get(next, "/assets/shared-A1234567.js", secret); code != 200 {
		t.Fatalf("offline chunk: %d", code)
	}
	if code, _ := get(next, "/trpc/read", secret); code != 503 {
		t.Fatalf("offline RPC: %d", code)
	}

	breakUpdate.Store(true)
	version.Store(2)
	next.Attach(target, &http.Transport{})
	select {
	case <-updateRequested:
	case <-time.After(4 * time.Second):
		t.Fatal("update did not request changed chunk")
	}
	if _, html := get(next, "/", secret); !strings.Contains(html, "version 1") {
		t.Fatal("incomplete update replaced cached shell")
	}

	breakUpdate.Store(false)
	next.Attach(target, &http.Transport{})
	wait(func() bool { _, html := get(next, "/", secret); return strings.Contains(html, "version 2") })
	if code, body := get(next, "/assets/entry-A1234562.js", secret); code != 200 || !strings.Contains(body, "updated code") {
		t.Fatalf("active shell lacks its changed chunk: %d %q", code, body)
	}
	if code, body := get(next, "/trpc/read", secret); code != 200 || !strings.Contains(body, "live data") {
		t.Fatalf("live RPC did not resume: %d %q", code, body)
	}
	if n := sharedDownloads.Load(); n != 1 {
		t.Fatalf("unchanged chunk downloaded %d times", n)
	}
}
