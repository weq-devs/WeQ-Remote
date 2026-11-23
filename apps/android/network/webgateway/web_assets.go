package webgateway

import (
	"bytes"
	"crypto/sha256"
	"io"
	"mime"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

const webAssetBudget = 12 << 20
const webAssetLimit = 8 << 20
const webAssetEntryLimit = 256
const webAssetWriteBatch = 16

var hashedWebCode = regexp.MustCompile(`^/assets/[^/]+-[A-Za-z0-9_-]{8,}\.(js|css)$`)

type webAsset struct {
	header http.Header
	body   []byte
}

type webAssetCache struct {
	mu           sync.Mutex
	entries      map[string]webAsset
	size         int
	directory    string
	disabled     bool
	pending      []webAssetWrite
	pendingBytes int
	writing      bool
}

type webAssetWrite struct {
	key   string
	asset webAsset
}

// 磁盘写入、淘汰与清空顺序执行；内存读取和文件读取都不等待写盘。
var webAssetDiskWrites sync.Mutex

var sharedWebAssets struct {
	sync.Mutex
	identity  [32]byte
	cache     *webAssetCache
	directory string
}

// ClearWebCache 清空内存和磁盘中的代码资源，包括尚未开始的写入。
func ClearWebCache() {
	sharedWebAssets.Lock()
	defer sharedWebAssets.Unlock()
	if cache := sharedWebAssets.cache; cache != nil {
		cache.disable()
	}
	webAssetDiskWrites.Lock()
	clearWebAssetFiles(sharedWebAssets.directory)
	webAssetDiskWrites.Unlock()
	sharedWebAssets.cache = nil
	sharedWebAssets.identity = [32]byte{}
}

type webAssetTransport struct {
	base      http.RoundTripper
	cache     *webAssetCache
	transfers *webAssetTransfers
}

func cachedWebTransport(base http.RoundTripper, token string) *webAssetTransport {
	if base == nil {
		base = http.DefaultTransport
	}
	// 选路已验证设备令牌。只有内容哈希固定的构建代码能跨同一授权的入口复用。
	identity := sha256.Sum256([]byte("weq-web-assets-v2\n" + token))
	sharedWebAssets.Lock()
	defer sharedWebAssets.Unlock()
	if sharedWebAssets.cache == nil || sharedWebAssets.identity != identity {
		if old := sharedWebAssets.cache; old != nil {
			old.disable()
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
	oldEncoding := req.Header.Get("Accept-Encoding")
	encoding := webCodeEncoding(oldEncoding)
	key := req.URL.RequestURI() + "\n" + encoding
	if asset, found := t.cache.load(key); found {
		return asset.response(req), nil
	}
	if encoding != oldEncoding {
		if asset, found := t.cache.load(req.URL.RequestURI() + "\n" + oldEncoding); found {
			return asset.response(req), nil
		}
		req = req.Clone(req.Context())
		req.Header.Set("Accept-Encoding", encoding)
	}
	if t.transfers != nil && req.Header.Get("If-Match") == "" && req.Header.Get("If-None-Match") == "" &&
		req.Header.Get("If-Modified-Since") == "" && req.Header.Get("If-Unmodified-Since") == "" {
		if response, err := t.transfers.open(req, key); response != nil || err != nil {
			return response, err
		}
	}
	return t.fetch(req, key)
}

// WeQ 静态服务支持 gzip 和原始正文。统一浏览器可接受的 gzip 请求以便与后台共用。
func webCodeEncoding(value string) string {
	var specific, accepted, wildcard bool
	for _, entry := range strings.Split(value, ",") {
		name, params, _ := strings.Cut(strings.TrimSpace(entry), ";")
		name = strings.TrimSpace(name)
		if !strings.EqualFold(name, "gzip") && name != "*" {
			continue
		}
		weight := 1.0
		for _, param := range strings.Split(params, ";") {
			key, weightText, _ := strings.Cut(strings.TrimSpace(param), "=")
			if strings.EqualFold(key, "q") {
				weight, _ = strconv.ParseFloat(weightText, 64)
			}
		}
		valid := weight > 0 && weight <= 1
		if name == "*" {
			wildcard = valid
		} else {
			specific, accepted = true, valid
		}
	}
	if accepted || !specific && wildcard {
		return "gzip"
	}
	return value
}

func (a webAsset) response(req *http.Request) *http.Response {
	header := a.header.Clone()
	if header == nil {
		header = make(http.Header)
	}
	header.Add("Server-Timing", `weq-remote-source;desc="cache"`)
	return &http.Response{StatusCode: http.StatusOK, Status: "200 OK", Header: header,
		Body: io.NopCloser(bytes.NewReader(a.body)), ContentLength: int64(len(a.body)), Request: req}
}

func (t *webAssetTransport) fetch(req *http.Request, key string) (*http.Response, error) {
	response, err := t.base.RoundTrip(req)
	if err != nil {
		return response, err
	}
	if response.Header == nil {
		response.Header = make(http.Header)
	}
	// 缓存只保存上游头，来源标识按本次实际读取重新生成，不持久化旧命中状态。
	cacheHeader := response.Header.Clone()
	response.Header.Add("Server-Timing", `weq-remote-source;desc="network"`)
	if _, persist := webAssetPolicy(response); persist {
		response.Body = &cachingWebBody{source: response.Body, cache: t.cache, key: key, header: cacheHeader, expected: response.ContentLength}
	}
	return response, nil
}

func webAssetPolicy(response *http.Response) (share, persist bool) {
	if response.StatusCode != http.StatusOK || response.ContentLength > webAssetLimit ||
		len(response.Header.Values("Set-Cookie")) > 0 || len(response.Trailer) != 0 {
		return false, false
	}
	mediaType, _, _ := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if mediaType != "text/javascript" && mediaType != "application/javascript" && mediaType != "text/css" {
		return false, false
	}
	// 开发版的 private 分包仅在当前授权、当前选路内共用。跨选路及写盘仍要求 public。
	directives := make(map[string]bool)
	for _, part := range strings.Split(strings.ToLower(strings.Join(response.Header.Values("Cache-Control"), ",")), ",") {
		name, _, hasValue := strings.Cut(strings.TrimSpace(part), "=")
		if name == "private" || name == "no-cache" || name == "no-store" || !hasValue {
			directives[name] = true
		}
	}
	if !directives["immutable"] || directives["no-store"] || directives["no-cache"] ||
		!(directives["public"] || directives["private"]) {
		return false, false
	}
	for _, vary := range strings.Split(strings.Join(response.Header.Values("Vary"), ","), ",") {
		if value := strings.TrimSpace(vary); value != "" && !strings.EqualFold(value, "Accept-Encoding") {
			return false, false
		}
	}
	return true, directives["public"] && !directives["private"]
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

func (c *webAssetCache) disable() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.disabled = true
	c.entries = nil
	c.size = 0
	c.pending = nil
	c.pendingBytes = 0
}

func (c *webAssetCache) memoryAsset(key string) (webAsset, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	asset, found := c.entries[key]
	return asset, found
}

func (c *webAssetCache) load(key string) (webAsset, bool) {
	c.mu.Lock()
	asset, found := c.entries[key]
	directory := c.directory
	disabled := c.disabled
	c.mu.Unlock()
	if found || disabled || directory == "" {
		return asset, found
	}

	asset, found = readWebAsset(directory, key)
	if !found {
		return webAsset{}, false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.disabled {
		return webAsset{}, false
	}
	if existing, exists := c.entries[key]; exists {
		return existing, true
	}
	c.remember(key, asset)
	return asset, true
}

func (c *webAssetCache) put(key string, asset webAsset) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.disabled {
		return
	}
	if _, exists := c.entries[key]; exists {
		return
	}
	c.remember(key, asset)
	if c.directory == "" || c.pendingBytes+len(asset.body) > webAssetBudget ||
		len(c.pending) >= webAssetEntryLimit {
		return
	}
	c.pending = append(c.pending, webAssetWrite{key: key, asset: asset})
	c.pendingBytes += len(asset.body)
	if !c.writing {
		c.writing = true
		go c.persist()
	}
}

// 调用方持有 c.mu。
func (c *webAssetCache) remember(key string, asset webAsset) {
	if c.size+len(asset.body) > webAssetBudget || len(c.entries) >= webAssetEntryLimit {
		c.entries = make(map[string]webAsset)
		c.size = 0
	}
	c.entries[key] = asset
	c.size += len(asset.body)
}

func (c *webAssetCache) persist() {
	for {
		// 先等上一批磁盘操作，再一次取走已收到的资源，避免每个文件都扫描缓存目录。
		webAssetDiskWrites.Lock()
		c.mu.Lock()
		count := min(len(c.pending), webAssetWriteBatch)
		if count == 0 {
			c.pending = nil
			c.writing = false
			c.mu.Unlock()
			webAssetDiskWrites.Unlock()
			return
		}
		batch := c.pending[:count:count]
		// 批次与待写队列使用互不重叠的槽位。
		c.pending = c.pending[count:]
		c.mu.Unlock()

		size := 0
		changed := false
		for _, entry := range batch {
			size += len(entry.asset.body)
			if writeWebAsset(c.directory, entry.key, entry.asset) {
				changed = true
			}
		}
		if changed {
			pruneWebAssetFiles(c.directory)
		}
		clear(batch)
		c.mu.Lock()
		if !c.disabled {
			c.pendingBytes -= size
		}
		c.mu.Unlock()
		webAssetDiskWrites.Unlock()
	}
}
