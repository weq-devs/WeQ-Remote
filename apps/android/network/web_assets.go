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
const webAssetEntryLimit = 256

var hashedWebCode = regexp.MustCompile(`^/assets/[^/]+-[A-Za-z0-9_-]{8,}\.(js|css)$`)

type webAsset struct {
	header http.Header
	body   []byte
}

type webAssetCache struct {
	mu        sync.Mutex
	entries   map[string]webAsset
	size      int
	directory string
	disabled  bool
}

var sharedWebAssets struct {
	sync.Mutex
	identity  [32]byte
	cache     *webAssetCache
	directory string
}

// ClearWebCache 删除应用内存中的代码资源；不持久保存授权或业务数据。
func ClearWebCache() {
	sharedWebAssets.Lock()
	defer sharedWebAssets.Unlock()
	if cache := sharedWebAssets.cache; cache != nil {
		cache.mu.Lock()
		cache.disabled = true
		cache.entries = make(map[string]webAsset)
		cache.size = 0
		cache.mu.Unlock()
	}
	clearWebAssetFiles(sharedWebAssets.directory)
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
		if old := sharedWebAssets.cache; old != nil {
			old.mu.Lock()
			old.disabled = true
			old.entries = make(map[string]webAsset)
			old.size = 0
			old.mu.Unlock()
		}
		sharedWebAssets.cache = &webAssetCache{entries: make(map[string]webAsset), directory: webAssetDirectory(sharedWebAssets.directory, identity)}
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
	if !found && !t.cache.disabled {
		asset, found = readWebAsset(t.cache.directory, key)
	}
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
	response.Body = &cachingWebBody{source: response.Body, cache: t.cache, key: key, header: response.Header.Clone(), expected: response.ContentLength}
	return response, nil
}

// 不预读响应体；浏览器立即收到响应头及后续数据，仅完整 EOF 才提交缓存。
type cachingWebBody struct {
	source   io.ReadCloser
	cache    *webAssetCache
	key      string
	header   http.Header
	expected int64
	buffer   bytes.Buffer
	failed   bool
	complete bool
}

func (b *cachingWebBody) Read(p []byte) (int, error) {
	n, err := b.source.Read(p)
	if !b.failed && !b.complete {
		if b.buffer.Len()+n > webAssetLimit {
			b.failed = true
			b.buffer.Reset()
		} else {
			_, _ = b.buffer.Write(p[:n])
		}
		if err == io.EOF && !b.failed && (b.expected < 0 || int64(b.buffer.Len()) == b.expected) {
			b.complete = true
			b.cache.put(b.key, webAsset{header: b.header, body: b.buffer.Bytes()})
		} else if err != nil {
			b.failed = true
		}
	}
	return n, err
}

func (b *cachingWebBody) Close() error { b.failed = true; return b.source.Close() }

func (c *webAssetCache) put(key string, asset webAsset) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.disabled {
		return
	}
	if _, exists := c.entries[key]; exists {
		return
	}
	if c.size+len(asset.body) > webAssetBudget || len(c.entries) >= webAssetEntryLimit {
		c.entries = make(map[string]webAsset)
		c.size = 0
	}
	c.entries[key] = asset
	c.size += len(asset.body)
	writeWebAsset(c.directory, key, asset)
}
