package androidnet

import (
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWebAssetResponseHeadersDoNotWaitForBody(t *testing.T) {
	reader, writer := io.Pipe()
	defer reader.Close()
	defer writer.Close()
	cache := &webAssetCache{entries: make(map[string]webAsset)}
	transport := &webAssetTransport{cache: cache, base: assetRoundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: http.Header{"Cache-Control": {"public, immutable"}, "Content-Type": {"text/javascript"}}, Body: reader, ContentLength: -1}, nil
	})}
	request, _ := http.NewRequest("GET", "http://100.64.0.1:7691/assets/index-Abcd1234.js", nil)
	response := make(chan *http.Response, 1)
	go func() { result, _ := transport.RoundTrip(request); response <- result }()
	var result *http.Response
	select {
	case result = <-response:
	case <-time.After(time.Second):
		t.Fatal("response headers waited for the unread body")
	}
	go func() {
		_, _ = io.WriteString(writer, "first")
		_ = writer.CloseWithError(errors.New("synthetic disconnect"))
	}()
	body, err := io.ReadAll(result.Body)
	_ = result.Body.Close()
	if string(body) != "first" || err == nil {
		t.Fatalf("stream lost data or error: %q %v", body, err)
	}
	if len(cache.entries) != 0 {
		t.Fatal("partial response entered cache")
	}
}

func TestCodeCacheSurvivesProcessMemoryAndRejectsPartialClose(t *testing.T) {
	directory := t.TempDir()
	calls := 0
	base := assetRoundTripFunc(func(*http.Request) (*http.Response, error) {
		calls++
		return &http.Response{StatusCode: 200, Header: http.Header{"Cache-Control": {"public, immutable"}, "Content-Type": {"text/javascript"}}, Body: io.NopCloser(strings.NewReader("synthetic-code")), ContentLength: 14}, nil
	})
	request, _ := http.NewRequest("GET", "http://100.64.0.1:7691/assets/index-Abcd1234.js", nil)
	open := func() *webAssetTransport {
		return &webAssetTransport{base: base, cache: &webAssetCache{entries: make(map[string]webAsset), directory: directory}}
	}
	first, _ := open().RoundTrip(request)
	_, _ = first.Body.Read(make([]byte, 3))
	_ = first.Body.Close()
	files, _ := filepath.Glob(filepath.Join(directory, "*.json"))
	if len(files) != 0 {
		t.Fatal("closing a partial response persisted it")
	}
	second, _ := open().RoundTrip(request)
	_, _ = io.Copy(io.Discard, second.Body)
	_ = second.Body.Close()
	third, _ := open().RoundTrip(request)
	body, err := io.ReadAll(third.Body)
	_ = third.Body.Close()
	if err != nil || string(body) != "synthetic-code" || calls != 2 {
		t.Fatalf("disk cache missed: calls=%d, body=%q, err=%v", calls, body, err)
	}
	files, _ = filepath.Glob(filepath.Join(directory, "*.json"))
	if len(files) != 1 {
		t.Fatal("missing atomic cache entry")
	}
	if err := os.WriteFile(files[0], []byte("corrupt"), 0600); err != nil {
		t.Fatal(err)
	}
	res, _ := open().RoundTrip(request)
	_, _ = io.Copy(io.Discard, res.Body)
	_ = res.Body.Close()
	if calls != 3 {
		t.Fatal("corrupt entry prevented refetch")
	}
}

type assetRoundTripFunc func(*http.Request) (*http.Response, error)

func (f assetRoundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestWebAssetCacheRejectsUnsafeResponses(t *testing.T) {
	for _, kind := range []string{"private", "no-store", "no-cache", "private=\"Set-Cookie\"", "no-cache=\"Authorization\"", "cookie", "vary", "error", "html"} {
		t.Run(kind, func(t *testing.T) {
			calls := 0
			transport := &webAssetTransport{cache: &webAssetCache{entries: make(map[string]webAsset)}, base: assetRoundTripFunc(func(r *http.Request) (*http.Response, error) {
				calls++
				header := http.Header{"Cache-Control": {"public, max-age=31536000, immutable"}, "Content-Type": {"text/javascript"}}
				status := 200
				switch kind {
				case "private", "no-store", "no-cache", "private=\"Set-Cookie\"", "no-cache=\"Authorization\"":
					header.Add("Cache-Control", kind)
				case "cookie":
					header.Set("Set-Cookie", "synthetic=value")
				case "vary":
					header.Add("Vary", "Cookie")
				case "error":
					status = 401
				case "html":
					header.Set("Content-Type", "text/html")
				}
				return &http.Response{StatusCode: status, Header: header, Body: io.NopCloser(strings.NewReader("synthetic")), ContentLength: 9}, nil
			})}
			for i := 0; i < 2; i++ {
				req, _ := http.NewRequest("GET", "http://100.64.0.1:7691/assets/index-Abcd1234.js", nil)
				res, err := transport.RoundTrip(req)
				if err != nil {
					t.Fatal(err)
				}
				_, _ = io.Copy(io.Discard, res.Body)
				_ = res.Body.Close()
			}
			if calls != 2 {
				t.Fatal("unsafe response was cached")
			}
		})
	}
}

func TestWebAssetCacheBoundsAndOversizeStreaming(t *testing.T) {
	cache := &webAssetCache{entries: make(map[string]webAsset)}
	body := strings.Repeat("x", 5<<20)
	transport := &webAssetTransport{cache: cache, base: assetRoundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: http.Header{"Cache-Control": {"public, immutable"}, "Content-Type": {"text/javascript"}}, Body: io.NopCloser(strings.NewReader(body)), ContentLength: -1}, nil
	})}
	for _, name := range []string{"first", "second", "third"} {
		req, _ := http.NewRequest("GET", "http://100.64.0.1:7691/assets/"+name+"-Abcd1234.js", nil)
		res, err := transport.RoundTrip(req)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.Copy(io.Discard, res.Body)
		_ = res.Body.Close()
		if cache.size > webAssetBudget {
			t.Fatal("cache exceeded memory budget")
		}
	}
	body = strings.Repeat("z", webAssetLimit+20)
	req, _ := http.NewRequest("GET", "http://100.64.0.1:7691/assets/large-Abcd1234.js", nil)
	res, err := transport.RoundTrip(req)
	if err != nil {
		t.Fatal(err)
	}
	data, err := io.ReadAll(res.Body)
	_ = res.Body.Close()
	if err != nil || string(data) != body {
		t.Fatal("oversized stream was truncated")
	}
	if _, found := cache.entries[req.URL.RequestURI()+"\n"]; found {
		t.Fatal("oversized asset entered cache")
	}
}
