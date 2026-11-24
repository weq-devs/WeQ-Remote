package webgateway

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
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
	var htmlBodies, unchangedChecks, manualChecks atomic.Int32
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
			if r.Header.Get("Cache-Control") == "no-cache" {
				manualChecks.Add(1)
			}
			current := version.Load()
			if current == 4 {
				io.WriteString(w, "<html><head></head><body>online-only Web</body></html>")
				return
			}
			body := fmt.Sprintf(`<html><head>%s<meta name="weq-startup-resources" content='{"version":1,"resources":[{"path":"/assets/shared-A1234567.js"},{"path":"/assets/entry-A123456%d.js"}]}'></head><body>version %d</body></html>`, offlineMarker, current, current)
			tag := fmt.Sprintf(`"weq-release-%x"`, sha256.Sum256([]byte(body)))
			w.Header().Set("ETag", tag)
			if r.Header.Get("If-None-Match") == tag {
				unchangedChecks.Add(1)
				w.WriteHeader(http.StatusNotModified)
				return
			}
			htmlBodies.Add(1)
			io.WriteString(w, body)
		case "/assets/shared-A1234567.js", "/assets/entry-A1234561.js", "/startup-theme.js":
			if r.URL.Path == "/assets/shared-A1234567.js" {
				sharedDownloads.Add(1)
			}
			w.Header().Set("Content-Type", "text/javascript")
			fmt.Fprintln(w, "/* cached code */")
		case "/assets/entry-A1234562.js", "/assets/entry-A1234563.js":
			if breakUpdate.Load() {
				w.WriteHeader(503)
				select {
				case updateRequested <- struct{}{}:
				default:
				}
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

	next.Attach(target, &http.Transport{})
	wait(func() bool { return unchangedChecks.Load() == 1 })
	previous := next.release()
	if n := htmlBodies.Load(); n != 1 {
		t.Fatalf("unchanged release downloaded %d HTML bodies, want 1", n)
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
	wait(func() bool { return next.release() != previous })
	if _, html := get(next, "/", secret); !strings.Contains(html, "version 1") {
		t.Fatal("preparing an update changed the document without confirmation")
	}
	if _, version := get(next, updatePath+"?workspace=1", secret); version != previous {
		t.Fatal("legacy release watcher would reload automatically")
	}
	if _, version := get(next, updatePath+"?notice=1", secret); version != next.release() {
		t.Fatal("notice watcher did not see the complete candidate")
	}
	if !next.Reload() || manualChecks.Load() != 1 {
		t.Fatal("manual reload did not revalidate the prepared candidate with the computer")
	}
	if _, html := get(next, "/", secret); !strings.Contains(html, "version 2") {
		t.Fatal("manual reload did not activate candidate")
	}
	if code, body := get(next, "/assets/entry-A1234562.js", secret); code != 200 || !strings.Contains(body, "updated code") {
		t.Fatalf("active shell lacks its changed chunk: %d %q", code, body)
	}
	if code, body := get(next, "/trpc/read", secret); code != 200 || !strings.Contains(body, "live data") {
		t.Fatalf("live RPC did not resume: %d %q", code, body)
	}
	if n := sharedDownloads.Load(); n != 1 {
		t.Fatalf("unchanged chunk downloaded %d times", n)
	}
	// 连接状态仍记录第二版。点击应立即发现第三版，无需等待后台再次检查。
	next.SetUpstreamRelease(next.release())
	version.Store(3)
	breakUpdate.Store(true)
	if next.Reload() || manualChecks.Load() != 2 {
		t.Fatal("manual reload failed to check the computer or accepted incomplete code")
	}
	if _, html := get(next, "/", secret); !strings.Contains(html, "version 2") {
		t.Fatal("failed manual reload replaced the active page")
	}
	breakUpdate.Store(false)
	if !next.Reload() || manualChecks.Load() != 3 {
		t.Fatal("retry should check again immediately, even during the polling cooldown")
	}
	if _, html := get(next, "/", secret); !strings.Contains(html, "version 3") {
		t.Fatal("manual reload did not activate freshly downloaded code")
	}

	cached := next.release()
	version.Store(4)
	if !next.Reload() {
		t.Fatal("manual reload did not allow loading from an online-only computer")
	}
	if _, html := get(next, "/", secret); !strings.Contains(html, "online-only Web") || next.release() != cached {
		t.Fatal("online reload continued serving the previous shell or erased its offline copy")
	}
}

func TestManualReloadPreemptsBlockedBackgroundCheck(t *testing.T) {
	if err := SetWebCacheDirectory(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ClearWebCache()
		sharedWebAssets.Lock()
		sharedWebAssets.directory = ""
		sharedWebAssets.Unlock()
	})
	checking, canceled := make(chan struct{}), make(chan struct{})
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cache-Control") == "no-cache" {
			w.Header().Set("Content-Type", "text/html")
			io.WriteString(w, "<html>online page</html>")
			return
		}
		close(checking)
		<-r.Context().Done()
		close(canceled)
	}))
	t.Cleanup(upstream.Close)
	gateway, err := Open(strings.Repeat("d", 64), strings.Repeat("e", 64))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(gateway.Close)
	target, _ := url.Parse(upstream.URL)
	gateway.Attach(target, &http.Transport{})
	select {
	case <-checking:
	case <-time.After(4 * time.Second):
		t.Fatal("background check did not reach the computer")
	}
	result := make(chan bool, 1)
	go func() { result <- gateway.Reload() }()
	select {
	case ok := <-result:
		if !ok {
			t.Fatal("manual reload did not obtain the online page")
		}
	case <-time.After(4 * time.Second):
		t.Fatal("manual reload waited for the blocked background check")
	}
	select {
	case <-canceled:
	case <-time.After(4 * time.Second):
		t.Fatal("background request was not canceled")
	}
}

func TestStableReleaseDoesNotRequestCodeAgainOnReconnect(t *testing.T) {
	if err := SetWebCacheDirectory(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ClearWebCache()
		sharedWebAssets.Lock()
		sharedWebAssets.directory = ""
		sharedWebAssets.Unlock()
	})
	const lazy = "/assets/Tool-A1234567.js"
	const shell = `<html><head>` + offlineMarker + `<meta name="weq-offline-code" content='{"version":1,"resources":[{"path":"` + lazy + `"}]}'></head></html>`
	version := fmt.Sprintf("%x", sha256.Sum256([]byte(shell)))
	var codeRequests, dataRequests atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			codeRequests.Add(1)
			if r.Header.Get("Accept-Encoding") != "identity" {
				t.Error("requested an HTML variant different from the advertised digest")
			}
			w.Header().Set("Content-Type", "text/html")
			io.WriteString(w, shell)
		case lazy, "/startup-theme.js":
			codeRequests.Add(1)
			w.Header().Set("Content-Type", "text/javascript")
			io.WriteString(w, "export const ready = true;")
		case "/trpc/read":
			dataRequests.Add(1)
			io.WriteString(w, "live")
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()
	target, _ := url.Parse(upstream.URL)
	token, secret := strings.Repeat("d", 64), strings.Repeat("e", 64)
	gateway, err := Open(token, secret)
	if err != nil {
		t.Fatal(err)
	}
	defer gateway.Close()
	gateway.AttachRelease(target, &http.Transport{}, version)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	get := func(path string) string {
		t.Helper()
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, gateway.Origin()+path, nil)
		req.AddCookie(&http.Cookie{Name: "weq_remote_local", Value: secret})
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, err := io.ReadAll(res.Body)
		if err != nil || res.StatusCode != 200 {
			t.Fatalf("%s: %d %q %v", path, res.StatusCode, body, err)
		}
		return string(body)
	}
	if got := get(updatePath + "?workspace=1&notice=1&since="); got != version {
		t.Fatalf("candidate = %q", got)
	}
	for range 3 {
		gateway.AttachStartup(target, &http.Transport{}, version)
		gateway.SetUpstreamRelease(version)
		gateway.checkRelease(false, false)
		get("/")
		get(updatePath + "?notice=1")
		get(lazy + "?query=1")
		if got := get("/trpc/read"); got != "live" {
			t.Fatalf("business data = %q", got)
		}
	}
	if codeRequests.Load() != 3 || dataRequests.Load() != 3 {
		t.Fatalf("upstream code/data requests: %d/%d", codeRequests.Load(), dataRequests.Load())
	}
}

func TestOnlineStartupNeverFallsBackToAnUnconfirmedCachedDocument(t *testing.T) {
	root := t.TempDir()
	if err := SetWebCacheDirectory(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		sharedWebAssets.Lock()
		sharedWebAssets.directory = ""
		sharedWebAssets.Unlock()
	})
	token, secret, old := strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("c", 64)
	directory := releaseDirectory(token)
	if err := os.MkdirAll(filepath.Join(directory, old), 0700); err != nil {
		t.Fatal(err)
	}
	for path, value := range map[string]string{"current": old, filepath.Join(old, "index.html"): "cached page"} {
		if err := os.WriteFile(filepath.Join(directory, path), []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if !HasCachedRelease(root, token) || HasCachedRelease(root, secret) {
		t.Fatal("cache discovery must use only this authorization's published document")
	}
	for _, kind := range []struct {
		name, release, body string
		status              int
		attach              bool
	}{
		{"changed", strings.Repeat("d", 64), "current page", 200, true},
		{"legacy", "", "current page", 200, true},
		{"failed", strings.Repeat("e", 64), "unavailable", 503, true},
		{"cached after failure", "", "cached page", 200, false},
	} {
		t.Run(kind.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				if !kind.attach {
					t.Error("cache-only startup contacted the upstream")
				}
				w.Header().Set("Content-Type", "text/html")
				w.WriteHeader(kind.status)
				io.WriteString(w, kind.body)
			}))
			defer upstream.Close()
			gateway, err := Open(token, secret)
			if err != nil {
				t.Fatal(err)
			}
			defer gateway.Close()
			if kind.attach {
				target, _ := url.Parse(upstream.URL)
				gateway.AttachStartup(target, &http.Transport{}, kind.release)
			}
			req, _ := http.NewRequest(http.MethodGet, gateway.Origin()+"/", nil)
			req.AddCookie(&http.Cookie{Name: "weq_remote_local", Value: secret})
			response, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			body, err := io.ReadAll(response.Body)
			if err != nil || response.StatusCode != kind.status || string(body) != kind.body {
				t.Fatalf("got %d %q, read error %v", response.StatusCode, body, err)
			}
		})
	}
}

func TestFirstOfflineReleaseWaitsForWorkspace(t *testing.T) {
	if err := SetWebCacheDirectory(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ClearWebCache()
		sharedWebAssets.Lock()
		sharedWebAssets.directory = ""
		sharedWebAssets.Unlock()
	})
	const asset = "/assets/main-H1234567.js"
	var codeRequests atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			w.Header().Set("Content-Type", "text/html")
			fmt.Fprintf(w, `<html><head>%s<meta name="weq-offline-bundle" content='{"version":1,"waitForWorkspace":true,"resources":[{"path":"%s"}]}'></head></html>`, offlineMarker, asset)
		case asset, "/startup-theme.js":
			w.Header().Set("Content-Type", "text/javascript")
			codeRequests.Add(1)
			fmt.Fprintln(w, "/* cached code */")
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()

	token, secret := strings.Repeat("a", 64), strings.Repeat("b", 64)
	gateway, err := Open(token, secret)
	if err != nil {
		t.Fatal(err)
	}
	defer gateway.Close()
	target, _ := url.Parse(upstream.URL)
	gateway.Attach(target, &http.Transport{})
	wait := func(match func() bool) {
		t.Helper()
		deadline := time.Now().Add(4 * time.Second)
		for time.Now().Before(deadline) {
			if match() {
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
		t.Fatal("release did not reach expected state")
	}
	wait(func() bool {
		gateway.releaseMu.Lock()
		defer gateway.releaseMu.Unlock()
		return gateway.waitingWorkspace
	})
	gateway.checkRelease(false, false)
	if n := codeRequests.Load(); n != 0 || gateway.HasRelease() {
		t.Fatalf("account selection downloaded %d offline resources", n)
	}

	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, gateway.Origin()+updatePath+"?workspace=1&since=", nil)
	req.AddCookie(&http.Cookie{Name: "weq_remote_local", Value: secret})
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("workspace notification: HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(response.Body)
	if err != nil || !Credential(string(body)) || string(body) != gateway.release() {
		t.Fatalf("version waiter returned before the complete release: %q, %v", body, err)
	}
	if response.Header.Get("X-WeQ-Local-Release-Wait") != "1" {
		t.Fatal("gateway did not advertise version waiting")
	}
	if n := codeRequests.Load(); n != 2 {
		t.Fatalf("opening workspace downloaded %d resources, want asset and theme", n)
	}
}
