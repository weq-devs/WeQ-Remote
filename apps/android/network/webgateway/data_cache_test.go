package webgateway

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDataCacheEvictsLeastRecentlyReadAcrossRecordGroups(t *testing.T) {
	root := t.TempDir()
	cache := newDataCache(filepath.Join(root, "releases", "test"))
	cache.load()
	cache.limit = 3 * 1024
	write := func(name string) {
		t.Helper()
		w := cache.beginEntry(name, cachedDataHeader{Type: "application/json"}, 512, "0")
		if w == nil {
			t.Fatal("cannot start writing cache")
		}
		_, err := io.WriteString(w, strings.Repeat("x", 512))
		if !w.finish(err == nil) {
			t.Fatal("cannot save cache")
		}
	}
	first, second := cacheFileName("head"), cacheFileName("media")
	group := cacheFileName("business") + "-" + cacheFileName("directory")
	write(first)
	write(second)
	write(group)
	file, _, _ := cache.open("head", 0)
	if file == nil {
		t.Fatal("cannot read cache")
	}
	file.Close()
	write(cacheFileName("older page"))
	if _, kept := cache.entries[first]; !kept {
		t.Fatal("recently read head evicted")
	}
	if _, kept := cache.entries[second]; kept {
		t.Fatal("oldest media retained")
	}
	if _, kept := cache.entries[group]; !kept {
		t.Fatal("directory evicted too early")
	}
	if cache.bytes != 3*1024 {
		t.Fatalf("unexpected usage: %v", cache.bytes)
	}

	inflight := cache.begin("new", cachedDataHeader{Type: "application/json"}, 512, "0")
	if inflight == nil {
		t.Fatal("could not start inflight cache write")
	}
	if _, err := io.WriteString(inflight, "old generation"); err != nil {
		t.Fatal(err)
	}
	codeDir := filepath.Join(root, "releases", "test")
	if err := os.MkdirAll(codeDir, 0700); err != nil {
		t.Fatal(err)
	}
	code := filepath.Join(codeDir, "index.html")
	if err := os.WriteFile(code, []byte("code"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := cache.clear(); err != nil {
		t.Fatal(err)
	}
	if inflight.finish(true) {
		t.Fatal("pre-clear request committed after clear")
	}
	if status := cache.status(); status.Bytes != 0 || !status.Cleared {
		t.Fatalf("unexpected status: %+v", status)
	}
	if _, err := os.Stat(code); err != nil {
		t.Fatalf("cleared web code: %v", err)
	}
}

func TestGatewayDataCacheOfflineReplayAndIsolation(t *testing.T) {
	root := t.TempDir()
	token, secret := strings.Repeat("5", 64), strings.Repeat("6", 64)
	g, err := Open(token, secret)
	if err != nil {
		t.Fatal(err)
	}
	g.cache = newDataCache(filepath.Join(root, "releases", "test"))
	defer g.Close()
	scope := `["12345","source-a"]`
	query := url.Values{"weqCacheScope": {scope}}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "video/mp4")
		if r.URL.Path != "/_media/unverified" {
			w.Header().Set("X-WeQ-Cache-Scope", url.PathEscape(scope))
		}
		if r.URL.Path == "/_media/segment" {
			w.Header().Set("Content-Range", "bytes 0-1/8")
			w.WriteHeader(206)
			_, _ = io.WriteString(w, "ab")
			return
		}
		_, _ = io.WriteString(w, "abcdefgh")
	}))
	defer upstream.Close()
	target, _ := url.Parse(upstream.URL)
	g.AttachRelease(target, upstream.Client().Transport, "")
	request := func(method, path, body, byteRange string, want int) string {
		t.Helper()
		r, err := http.NewRequest(method, g.origin+path, strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		r.AddCookie(&http.Cookie{Name: "weq_remote_local", Value: secret})
		r.Header.Set("X-WeQ-Cache-Generation", "0")
		if byteRange != "" {
			r.Header.Set("Range", byteRange)
		}
		response, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		data, err := io.ReadAll(response.Body)
		if err != nil || response.StatusCode != want {
			t.Fatalf("%s %s: %v %v %s", method, path, response.StatusCode, err, data)
		}
		return string(data)
	}
	full := "/_media/video?" + query.Encode()
	partial := "/_media/segment?" + query.Encode()
	expect := func(got, want string) {
		t.Helper()
		if got != want {
			t.Fatalf("got %q, want %q", got, want)
		}
	}
	records := dataCachePath + "/queries/" + cacheFileName("directory")
	request("PUT", records, `[{"key":"list","value":{"items":[1]}}]`, "", 204)
	expect(request("GET", records, "", "", 200), `[{"items":[1]}]`)
	expect(request("GET", full+"&cid=old", "", "", 200), "abcdefgh")
	expect(request("GET", partial, "", "bytes=0-1", 206), "ab")
	request("GET", "/_media/unverified?"+query.Encode(), "", "", 200)

	g.mu.Lock()
	g.detachLocked()
	g.mu.Unlock()
	expect(request("GET", full+"&cid=new", "", "bytes=2-4", 206), "cde")
	expect(request("GET", partial, "", "bytes=0-1", 206), "ab")
	request("GET", partial, "", "bytes=2-3", 503)
	request("GET", "/_media/unverified?"+query.Encode(), "", "", 503)
	query.Set("weqCacheScope", `["12345","source-b"]`)
	request("GET", "/_media/video?"+query.Encode(), "", "", 503)

	request("PUT", fmt.Sprintf("%s?limit=%d", dataCachePath, 16*dataCacheMiB), "", "", 200)
	request("DELETE", dataCachePath, "", "", 200)
	expect(request("GET", records, "", "", 200), "[]")
	reopened := newDataCache(filepath.Join(root, "releases", "test"))
	if status := reopened.status(); status.Limit != 16*dataCacheMiB || status.Bytes != 0 || !status.Cleared {
		t.Fatalf("settings did not survive reopen: %+v", status)
	}
}
