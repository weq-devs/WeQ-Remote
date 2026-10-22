package androidnet

import (
	"bytes"
	"crypto/sha256"
	"io"
	"mime"
	"net/http"
	"regexp"
	"strings"
	"sync"
)

const webAssetBudget = 12 << 20
const webAssetLimit = 8 << 20
const webAssetEntryLimit = 64

var hashedWebCode = regexp.MustCompile(`^/assets/[^/]+-[A-Za-z0-9_-]{8,}\.(js|css)$`)

type webAsset struct {
	header http.Header
	body   []byte
}

type webAssetCache struct {
	mu      sync.Mutex
	entries map[string]webAsset
	size    int
}

var sharedWebAssets struct {
	sync.Mutex
	identity [32]byte
	cache    *webAssetCache
}

// ClearWebCache 删除应用内存中的代码资源；不持久保存授权或业务数据。
func ClearWebCache() {
	sharedWebAssets.Lock()
	defer sharedWebAssets.Unlock()
	sharedWebAssets.cache = nil
	sharedWebAssets.identity = [32]byte{}
}

type webAssetTransport struct {
	base  http.RoundTripper
	cache *webAssetCache
}

func cachedWebTransport(base http.RoundTripper, endpoint, token string) http.RoundTripper {
	if base == nil {
		base = http.DefaultTransport
	}
	identity := sha256.Sum256([]byte(endpoint + "\n" + token))
	sharedWebAssets.Lock()
	defer sharedWebAssets.Unlock()
	if sharedWebAssets.cache == nil || sharedWebAssets.identity != identity {
		sharedWebAssets.cache = &webAssetCache{entries: make(map[string]webAsset)}
		sharedWebAssets.identity = identity
	}
	return &webAssetTransport{base: base, cache: sharedWebAssets.cache}
}

func (t *webAssetTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.Method != http.MethodGet || !hashedWebCode.MatchString(req.URL.Path) || req.Header.Get("Range") != "" {
		return t.base.RoundTrip(req)
	}
	key := req.URL.RequestURI() + "\n" + req.Header.Get("Accept-Encoding")
	t.cache.mu.Lock()
	asset, found := t.cache.entries[key]
	t.cache.mu.Unlock()
	if found {
		return &http.Response{StatusCode: http.StatusOK, Status: "200 OK", Header: asset.header.Clone(),
			Body: io.NopCloser(bytes.NewReader(asset.body)), ContentLength: int64(len(asset.body)), Request: req}, nil
	}
	response, err := t.base.RoundTrip(req)
	if err != nil || response.StatusCode != http.StatusOK || response.ContentLength > webAssetLimit || len(response.Header.Values("Set-Cookie")) > 0 {
		return response, err
	}
	mediaType, _, _ := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if mediaType != "text/javascript" && mediaType != "application/javascript" && mediaType != "text/css" {
		return response, nil
	}
	// 只接受明确标记 public + immutable 的构建代码，绝不缓存 HTML、接口或媒体。
	directives := make(map[string]bool)
	for _, part := range strings.Split(strings.ToLower(strings.Join(response.Header.Values("Cache-Control"), ",")), ",") {
		name, _, hasValue := strings.Cut(strings.TrimSpace(part), "=")
		if name == "private" || name == "no-cache" || name == "no-store" || !hasValue {
			directives[name] = true
		}
	}
	if !directives["public"] || !directives["immutable"] || directives["no-store"] || directives["private"] || directives["no-cache"] {
		return response, nil
	}
	for _, vary := range strings.Split(strings.Join(response.Header.Values("Vary"), ","), ",") {
		if value := strings.TrimSpace(vary); value != "" && !strings.EqualFold(value, "Accept-Encoding") {
			return response, nil
		}
	}
	body, readErr := io.ReadAll(io.LimitReader(response.Body, webAssetLimit+1))
	if readErr != nil {
		_ = response.Body.Close()
		return nil, readErr
	}
	if len(body) > webAssetLimit {
		response.Body = &prefixedWebBody{Reader: io.MultiReader(bytes.NewReader(body), response.Body), Closer: response.Body}
		return response, nil
	}
	_ = response.Body.Close()
	response.Body = io.NopCloser(bytes.NewReader(body))
	t.cache.mu.Lock()
	defer t.cache.mu.Unlock()
	if _, exists := t.cache.entries[key]; !exists {
		if t.cache.size+len(body) > webAssetBudget || len(t.cache.entries) >= webAssetEntryLimit {
			t.cache.entries = make(map[string]webAsset)
			t.cache.size = 0
		}
		t.cache.entries[key] = webAsset{header: response.Header.Clone(), body: body}
		t.cache.size += len(body)
	}
	return response, nil
}

type prefixedWebBody struct {
	io.Reader
	io.Closer
}
