package webgateway

import (
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestReleaseAndWebViewShareStreamingCode(t *testing.T) {
	for _, visibility := range []string{"public", "private"} {
		t.Run(visibility, func(t *testing.T) { testReleaseAndWebViewShareCode(t, visibility) })
	}
}

func TestWebCodeEncodingRespectsGzipQuality(t *testing.T) {
	for _, input := range []string{"br, gzip", "*;q=0.5"} {
		if got := webCodeEncoding(input); got != "gzip" {
			t.Errorf("webCodeEncoding(%q) = %q, want gzip", input, got)
		}
	}
	for _, input := range []string{"br", "gzip;q=2", "*;q=1, gzip;q=0", "gzip;q=1, gzip;q=0"} {
		if got := webCodeEncoding(input); got != input {
			t.Errorf("webCodeEncoding(%q) = %q, want original encoding", input, got)
		}
	}
}

func testReleaseAndWebViewShareCode(t *testing.T, visibility string) {
	const path = "/assets/main-H1234567.js"
	const first = "/* first chunk */"
	const last = "/* last chunk */"

	if err := SetWebCacheDirectory(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ClearWebCache()
		sharedWebAssets.Lock()
		sharedWebAssets.directory = ""
		sharedWebAssets.Unlock()
	})

	var codeDownloads atomic.Int32
	firstSent, finish := make(chan struct{}), make(chan struct{})
	var finishOnce sync.Once
	complete := func() { finishOnce.Do(func() { close(finish) }) }
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			w.Header().Set("Content-Type", "text/html")
			fmt.Fprintf(w, `<html><head>%s<meta name="weq-startup-resources" content='{"version":1,"resources":[{"path":"%s"}]}'></head></html>`, offlineMarker, path)
		case path:
			count := codeDownloads.Add(1)
			if got := r.Header.Get("Accept-Encoding"); got != "gzip" {
				t.Errorf("compression negotiation = %q", got)
			}
			w.Header().Set("Content-Type", "text/javascript")
			w.Header().Set("Cache-Control", visibility+", max-age=31536000, immutable")
			w.Header().Set("Vary", "Accept-Encoding")
			w.Header().Set("Content-Encoding", "gzip")
			encoded := gzip.NewWriter(w)
			defer encoded.Close()
			io.WriteString(encoded, first)
			encoded.Flush()
			w.(http.Flusher).Flush()
			if count == 1 {
				close(firstSent)
			}
			select {
			case <-finish:
				io.WriteString(encoded, last)
			case <-r.Context().Done():
			}
		case "/startup-theme.js":
			w.Header().Set("Content-Type", "text/javascript")
			fmt.Fprintln(w, "/* theme */")
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()
	defer complete()

	token, secret := strings.Repeat("a", 64), strings.Repeat("b", 64)
	gateway, err := Open(token, secret)
	if err != nil {
		t.Fatal(err)
	}
	defer gateway.Close()
	target, _ := url.Parse(upstream.URL)
	gateway.Attach(target, &http.Transport{})

	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	select {
	case <-firstSent:
	case <-ctx.Done():
		t.Fatal("offline refresh did not start downloading code")
	}
	get := func(ctx context.Context) *http.Response {
		t.Helper()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, gateway.Origin()+path, nil)
		if err != nil {
			t.Fatal(err)
		}
		req.AddCookie(&http.Cookie{Name: "weq_remote_local", Value: secret})
		req.Header.Set("Accept-Encoding", "gzip, deflate, br, zstd")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return res
	}
	browser, stopBrowser := context.WithCancel(ctx)
	defer stopBrowser()
	res := get(browser)
	reader, err := gzip.NewReader(res.Body)
	if err != nil {
		t.Fatal("foreground response headers and gzip must arrive before EOF:", err)
	}
	defer reader.Close()
	defer res.Body.Close()
	received := make([]byte, len(first))
	if _, err := io.ReadFull(reader, received); err != nil || string(received) != first {
		t.Fatalf("foreground did not receive the initial bytes before EOF: %q, %v", received, err)
	}
	if gateway.HasRelease() {
		t.Fatal("published incomplete offline release")
	}
	stopBrowser()
	res.Body.Close()
	complete()

	for !gateway.HasRelease() {
		select {
		case <-ctx.Done():
			t.Fatal("closing the WebView response cancelled the shared offline download")
		case <-time.After(5 * time.Millisecond):
		}
	}
	gateway.mu.Lock()
	gateway.detachLocked()
	gateway.mu.Unlock()
	offline := get(ctx)
	defer offline.Body.Close()
	decoded, err := io.ReadAll(offline.Body)
	if err != nil || offline.Header.Get("Content-Encoding") != "" || string(decoded) != first+last {
		t.Fatalf("offline release did not contain complete decoded code: %q, %v", decoded, err)
	}
	if n := codeDownloads.Load(); n != 1 {
		t.Fatalf("upstream downloads = %d, want 1", n)
	}
}

func TestSharedCodeAboveCacheBudgetKeepsStreaming(t *testing.T) {
	body, upstream := io.Pipe()
	defer body.Close()
	defer upstream.Close()
	var requests atomic.Int32
	transport := &webAssetTransport{
		cache: &webAssetCache{entries: make(map[string]webAsset)},
		base: assetRoundTripFunc(func(_ *http.Request) (*http.Response, error) {
			requests.Add(1)
			return &http.Response{StatusCode: 200, ContentLength: -1, Body: body, Header: http.Header{
				"Content-Type": {"text/javascript"}, "Cache-Control": {"public, immutable"},
			}}, nil
		}),
	}
	transport.transfers = newWebAssetTransfers(transport)
	defer transport.transfers.cancel()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "http://example.test/assets/main-H1234567.js", nil)
	responses := make([]*http.Response, 2)
	for i := range responses {
		res, err := transport.RoundTrip(req)
		if err != nil {
			t.Fatal(err)
		}
		responses[i] = res
		defer res.Body.Close()
	}

	chunk := strings.Repeat("x", 32<<10)
	size := webAssetLimit + len(chunk)*2
	go func() {
		defer upstream.Close()
		for remaining := size; remaining > 0; remaining -= len(chunk) {
			if _, err := io.WriteString(upstream, chunk); err != nil {
				return
			}
		}
	}()
	type readResult struct {
		n   int64
		err error
	}
	results := make(chan readResult, len(responses))
	for _, res := range responses {
		go func() {
			n, err := io.Copy(io.Discard, res.Body)
			results <- readResult{n, err}
		}()
	}
	for range responses {
		select {
		case result := <-results:
			if result.err != nil || result.n != int64(size) {
				t.Fatalf("shared stream did not deliver the complete response: %+v", result)
			}
		case <-ctx.Done():
			t.Fatal("shared stream stopped making progress")
		}
	}
	if requests.Load() != 1 || len(transport.cache.entries) != 0 {
		t.Fatalf("downloads = %d, oversized cache entries = %d", requests.Load(), len(transport.cache.entries))
	}
}
