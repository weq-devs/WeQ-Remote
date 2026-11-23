package webgateway

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const dataCachePath = "/_weq-remote-local/cache"
const dataCacheMiB = 1 << 20
const defaultDataCacheLimit = 256 * dataCacheMiB
const maxDataCacheLimit = 4096 * dataCacheMiB
const mediaFreshness = 5 * time.Minute

type dataCacheEntry struct {
	name          string
	size          int64
	used, touched time.Time
}

// 业务数据按电脑授权共用一个预算，网页代码有自己的目录与版本指针。
type dataCache struct {
	dir          string
	settings     string
	mu           sync.Mutex
	entries      map[string]dataCacheEntry
	bytes, limit int64
	generation   uint64
	writes       chan struct{}
	staging      atomic.Int64
}

func newDataCache(releaseDir string) *dataCache {
	if releaseDir == "" {
		return nil
	}
	dir := filepath.Join(filepath.Dir(filepath.Dir(releaseDir)), "data", filepath.Base(releaseDir))
	webStorage.Lock()
	storage := webStorage.directory
	webStorage.Unlock()
	settings := dir
	if storage != "" {
		settings = filepath.Join(storage, "data-settings", filepath.Base(releaseDir))
	}
	return &dataCache{dir: dir, settings: settings, writes: make(chan struct{}, 4)}
}

func (c *dataCache) load() {
	if c.entries != nil {
		return
	}
	c.entries = make(map[string]dataCacheEntry)
	c.limit = defaultDataCacheLimit
	if raw, err := os.ReadFile(filepath.Join(c.settings, "limit")); err == nil {
		if limit, err := strconv.ParseInt(string(raw), 10, 64); err == nil && validDataCacheLimit(limit) {
			c.limit = limit
		}
	}
	files, _ := os.ReadDir(c.dir)
	for _, file := range files {
		name := file.Name()
		if strings.HasPrefix(name, ".pending-") {
			_ = os.Remove(filepath.Join(c.dir, name))
			continue
		}
		group, id, grouped := strings.Cut(name, "-")
		if !(Credential(name) || grouped && Credential(group) && Credential(id)) {
			continue
		}
		if info, err := file.Info(); err == nil && info.Mode().IsRegular() {
			c.entries[name] = dataCacheEntry{name, info.Size(), info.ModTime(), info.ModTime()}
			c.bytes += info.Size()
		}
	}
	_ = c.trim(c.limit, "")
}

func validDataCacheLimit(value int64) bool {
	return value >= 16*dataCacheMiB && value <= maxDataCacheLimit && value%dataCacheMiB == 0
}

func (c *dataCache) remove(entry dataCacheEntry) error {
	if err := os.Remove(filepath.Join(c.dir, entry.name)); err != nil && !os.IsNotExist(err) {
		return err
	}
	delete(c.entries, entry.name)
	c.bytes -= entry.size
	return nil
}

func (c *dataCache) trim(target int64, except string) error {
	if c.bytes <= target {
		return nil
	}
	oldest := make([]dataCacheEntry, 0, len(c.entries))
	for _, entry := range c.entries {
		if entry.name != except {
			oldest = append(oldest, entry)
		}
	}
	sort.Slice(oldest, func(i, j int) bool {
		if oldest[i].used.Equal(oldest[j].used) {
			return oldest[i].name < oldest[j].name
		}
		return oldest[i].used.Before(oldest[j].used)
	})
	for _, entry := range oldest {
		if c.bytes <= target {
			break
		}
		if err := c.remove(entry); err != nil {
			return err
		}
	}
	return nil
}

type dataCacheStatus struct {
	Bytes      int64  `json:"bytes"`
	Limit      int64  `json:"limit"`
	Generation string `json:"generation"`
	Cleared    bool   `json:"cleared"`
}

func (c *dataCache) status() dataCacheStatus {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.load()
	_, err := os.Stat(filepath.Join(c.settings, "cleared"))
	return dataCacheStatus{c.bytes, c.limit, strconv.FormatUint(c.generation, 10), err == nil}
}

func (c *dataCache) setLimit(limit int64) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.load()
	if err := os.MkdirAll(c.settings, 0700); err != nil {
		return err
	}
	if err := c.trim(limit, ""); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(c.settings, "limit"), []byte(strconv.FormatInt(limit, 10)), 0600); err != nil {
		return err
	}
	c.limit = limit
	return nil
}

func (c *dataCache) clear() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.load()
	if err := os.MkdirAll(c.settings, 0700); err != nil {
		return err
	}
	// 阻止清除前开始的下载和旧 WebView 镜像重新填入。
	if err := os.WriteFile(filepath.Join(c.settings, "cleared"), nil, 0600); err != nil {
		return err
	}
	c.generation++
	return c.trim(0, "")
}

func cacheFileName(key string) string { return fmt.Sprintf("%x", sha256.Sum256([]byte(key))) }

type cachedDataHeader struct {
	Type     string
	Range    string
	StoredAt time.Time
}

func (c *dataCache) open(key string, maxAge time.Duration) (*os.File, cachedDataHeader, int64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.load()
	return c.openEntry(cacheFileName(key), maxAge)
}

func (c *dataCache) openEntry(name string, maxAge time.Duration) (*os.File, cachedDataHeader, int64) {
	entry, ok := c.entries[name]
	if !ok {
		return nil, cachedDataHeader{}, 0
	}
	file, err := os.Open(filepath.Join(c.dir, name))
	if err != nil {
		return nil, cachedDataHeader{}, 0
	}
	var prefix [512]byte
	var header cachedDataHeader
	if _, err := io.ReadFull(file, prefix[:]); err != nil ||
		json.Unmarshal(prefix[:], &header) != nil || entry.size <= int64(len(prefix)) ||
		(maxAge > 0 && time.Since(header.StoredAt) > maxAge) {
		file.Close()
		return nil, cachedDataHeader{}, 0
	}
	now := time.Now()
	if now.Sub(entry.touched) >= 30*time.Second && os.Chtimes(file.Name(), now, now) == nil {
		entry.touched = now
	}
	entry.used = now
	c.entries[name] = entry
	return file, header, entry.size - int64(len(prefix))
}

type dataCacheWrite struct {
	cache      *dataCache
	file       *os.File
	name       string
	generation uint64
	size, max  int64
}

func (c *dataCache) begin(key string, header cachedDataHeader, size int64, generation string) *dataCacheWrite {
	return c.beginEntry(cacheFileName(key), header, size, generation)
}

func (c *dataCache) beginEntry(name string, header cachedDataHeader, size int64, generation string) *dataCacheWrite {
	select {
	case c.writes <- struct{}{}:
	default:
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.load()
	if (generation != "" && generation != strconv.FormatUint(c.generation, 10)) ||
		size > c.limit-512 || os.MkdirAll(c.dir, 0700) != nil {
		<-c.writes
		return nil
	}
	file, err := os.CreateTemp(c.dir, ".pending-")
	if err != nil {
		<-c.writes
		return nil
	}
	result := &dataCacheWrite{c, file, name, c.generation, 0, c.limit}
	header.StoredAt = time.Now()
	encoded, _ := json.Marshal(header)
	if len(encoded) > 512 {
		result.finish(false)
		return nil
	}
	prefix := [512]byte{}
	for index := range prefix {
		prefix[index] = ' '
	}
	copy(prefix[:], encoded)
	if _, err := result.Write(prefix[:]); err != nil {
		result.finish(false)
		return nil
	}
	return result
}

func (w *dataCacheWrite) Write(p []byte) (int, error) {
	if int64(len(p)) > w.max-w.size {
		return 0, io.ErrShortWrite
	}
	reserved := int64(len(p))
	if w.cache.staging.Add(reserved) > w.max {
		w.cache.staging.Add(-reserved)
		return 0, io.ErrShortWrite
	}
	n, err := w.file.Write(p)
	w.cache.staging.Add(int64(n) - reserved)
	w.size += int64(n)
	return n, err
}

func (w *dataCacheWrite) finish(complete bool) bool {
	c := w.cache
	defer func() {
		_ = os.Remove(w.file.Name())
		c.staging.Add(-w.size)
		<-c.writes
	}()
	if w.file.Close() != nil || !complete || w.size <= 512 {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if w.generation != c.generation || w.size > c.limit {
		return false
	}
	previous := c.entries[w.name]
	if c.trim(c.limit-w.size+previous.size, w.name) != nil {
		return false
	}
	if os.Rename(w.file.Name(), filepath.Join(c.dir, w.name)) != nil {
		return false
	}
	c.entries[w.name] = dataCacheEntry{w.name, w.size, time.Now(), time.Now()}
	c.bytes += w.size - previous.size
	return true
}

func (c *dataCache) serveEntry(w http.ResponseWriter, r *http.Request, key string, maxAge time.Duration) bool {
	file, header, size := c.open(key, maxAge)
	if file == nil {
		return false
	}
	defer file.Close()
	w.Header().Set("Content-Type", header.Type)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-WeQ-Data-Cache", "1")
	w.Header().Set("X-WeQ-Cache-Stored-At", strconv.FormatInt(header.StoredAt.UnixMilli(), 10))
	if header.Range != "" {
		w.Header().Set("Content-Range", header.Range)
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
		w.WriteHeader(http.StatusPartialContent)
		if r.Method != http.MethodHead {
			_, _ = io.CopyN(w, file, size)
		}
	} else {
		http.ServeContent(w, r, "", time.Time{}, io.NewSectionReader(file, 512, size))
	}
	return true
}

func mediaCacheKey(u *url.URL) string {
	switch {
	case u.Path == "/_media/flashpic":
		return ""
	case strings.HasPrefix(u.Path, "/_media/"), strings.HasPrefix(u.Path, "/_avatar/"), strings.HasPrefix(u.Path, "/_asset/"):
	default:
		return ""
	}
	q := u.Query()
	scope := q.Get("weqCacheScope")
	var account []string
	if !(scope == "assets" && strings.HasPrefix(u.Path, "/_asset/")) &&
		(len(scope) > 1024 || json.Unmarshal([]byte(scope), &account) != nil ||
			len(account) != 2 || account[0] == "" || account[1] == "") {
		return ""
	}
	// 策略与页面客户端标识不改变资源身份。保留清晰度、版本、账号和所有内容参数。
	for _, param := range []string{"cid", "intent", "auto", "cacheOnly"} {
		q.Del(param)
	}
	return "media:" + u.Path + "?" + q.Encode()
}

func validCacheMedia(value string) bool {
	kind, _, err := mime.ParseMediaType(value)
	return err == nil && len(kind) <= 100 && (strings.HasPrefix(kind, "image/") ||
		strings.HasPrefix(kind, "audio/") || strings.HasPrefix(kind, "video/") ||
		strings.HasPrefix(kind, "font/") || kind == "application/font-woff" ||
		kind == "application/x-font-ttf" || kind == "application/octet-stream" || kind == "application/pdf")
}

func (c *dataCache) serve(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-WeQ-Data-Cache", "1")
	if r.URL.Path == dataCachePath {
		switch r.Method {
		case http.MethodGet:
		case http.MethodPut:
			limit, err := strconv.ParseInt(r.URL.Query().Get("limit"), 10, 64)
			if err != nil || !validDataCacheLimit(limit) {
				http.Error(w, "Invalid limit", 400)
				return
			}
			if c.setLimit(limit) != nil {
				http.Error(w, "Cache unavailable", 503)
				return
			}
		case http.MethodDelete:
			if c.clear() != nil {
				http.Error(w, "Cache unavailable", 503)
				return
			}
		default:
			w.WriteHeader(405)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(c.status())
		return
	}
	key := strings.TrimPrefix(r.URL.Path, dataCachePath+"/")
	if group, ok := strings.CutPrefix(key, "queries/"); ok && Credential(group) {
		c.serveQueries(w, r, group)
		return
	}
	media := "application/json"
	if key == "media" {
		source, err := url.ParseRequestURI(r.URL.Query().Get("source"))
		if err != nil || source.IsAbs() {
			http.NotFound(w, r)
			return
		}
		key = mediaCacheKey(source)
		media = r.Header.Get("Content-Type")
		if r.Method == http.MethodPut && !validCacheMedia(media) {
			http.Error(w, "Invalid media", 400)
			return
		}
	} else if Credential(key) {
		key = "record:" + key
	} else {
		key = ""
	}
	if key == "" {
		http.NotFound(w, r)
		return
	}
	switch r.Method {
	case http.MethodGet:
		if !c.serveEntry(w, r, key, 0) {
			http.NotFound(w, r)
		}
	case http.MethodPut:
		generation := r.Header.Get("X-WeQ-Cache-Generation")
		if generation == "" {
			http.Error(w, "Missing cache generation", 400)
			return
		}
		write := c.begin(key, cachedDataHeader{Type: media}, r.ContentLength, generation)
		if write == nil {
			http.Error(w, "Cache busy or full", 409)
			return
		}
		n, err := io.Copy(write, r.Body)
		if !write.finish(err == nil && (r.ContentLength < 0 || r.ContentLength == n)) {
			http.Error(w, "Cache write incomplete", 409)
			return
		}
		w.WriteHeader(204)
	default:
		w.WriteHeader(405)
	}
}

// 目录记录各自计量和淘汰。改变一条摘要时只传输、写入这一条。
func (c *dataCache) serveQueries(w http.ResponseWriter, r *http.Request, group string) {
	prefix := group + "-"
	switch r.Method {
	case http.MethodGet:
		c.mu.Lock()
		c.load()
		var names []string
		for name := range c.entries {
			if strings.HasPrefix(name, prefix) {
				names = append(names, name)
			}
		}
		c.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, "[")
		first := true
		for _, name := range names {
			if r.Context().Err() != nil {
				return
			}
			c.mu.Lock()
			file, _, size := c.openEntry(name, 0)
			c.mu.Unlock()
			if file == nil {
				continue
			}
			if !first {
				_, _ = io.WriteString(w, ",")
			}
			_, err := io.CopyN(w, file, size)
			file.Close()
			if err != nil {
				return
			}
			first = false
		}
		_, _ = io.WriteString(w, "]")
	case http.MethodPut:
		generation := r.Header.Get("X-WeQ-Cache-Generation")
		status := c.status()
		if generation != status.Generation {
			http.Error(w, "Cache cleared", 409)
			return
		}
		reader := json.NewDecoder(http.MaxBytesReader(w, r.Body, status.Limit))
		if token, err := reader.Token(); err != nil || token != json.Delim('[') {
			http.Error(w, "Invalid records", 400)
			return
		}
		for reader.More() {
			var row struct {
				Key   string
				Value json.RawMessage
			}
			if err := reader.Decode(&row); err != nil || row.Key == "" || len(row.Value) == 0 {
				http.Error(w, "Invalid record", 400)
				return
			}
			write := c.beginEntry(prefix+cacheFileName(row.Key), cachedDataHeader{Type: "application/json"}, int64(len(row.Value)), generation)
			if write == nil {
				http.Error(w, "Cache busy or full", 409)
				return
			}
			_, err := write.Write(row.Value)
			if !write.finish(err == nil) {
				http.Error(w, "Cache write incomplete", 409)
				return
			}
		}
		if token, err := reader.Token(); err != nil || token != json.Delim(']') {
			http.Error(w, "Invalid records", 400)
			return
		}
		w.WriteHeader(204)
	default:
		w.WriteHeader(405)
	}
}

type cacheMediaBody struct {
	io.ReadCloser
	write              *dataCacheWrite
	expected, received int64
}

func (b *cacheMediaBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	if b.write != nil {
		b.received += int64(n)
		if _, writeErr := b.write.Write(p[:n]); writeErr != nil || err != nil {
			b.write.finish(writeErr == nil && err == io.EOF && (b.expected < 0 || b.expected == b.received))
			b.write = nil
		}
	}
	return n, err
}

func (b *cacheMediaBody) Close() error {
	if b.write != nil {
		b.write.finish(b.expected >= 0 && b.expected == b.received)
		b.write = nil
	}
	return b.ReadCloser.Close()
}

func partialMediaKey(key, requestRange string) string {
	if requestRange == "" || len(requestRange) > 100 || strings.Contains(requestRange, ",") ||
		!strings.HasPrefix(requestRange, "bytes=") {
		return ""
	}
	return key + "\nrange:" + requestRange
}

func (g *Gateway) serveCachedMedia(w http.ResponseWriter, r *http.Request, maxAge time.Duration) bool {
	if g.cache == nil || (r.Method != http.MethodGet && r.Method != http.MethodHead) {
		return false
	}
	key := mediaCacheKey(r.URL)
	if key == "" {
		return false
	}
	g.secure(w.Header())
	if g.cache.serveEntry(w, r, key, maxAge) {
		return true
	}
	partial := partialMediaKey(key, r.Header.Get("Range"))
	return partial != "" && g.cache.serveEntry(w, r, partial, maxAge)
}

func (c *dataCache) captureMedia(response *http.Response) {
	r := response.Request
	if r == nil || r.Method != http.MethodGet {
		return
	}
	key := mediaCacheKey(r.URL)
	if key == "" {
		return
	}
	if response.StatusCode == http.StatusServiceUnavailable || response.StatusCode == http.StatusBadGateway || response.StatusCode == http.StatusGatewayTimeout {
		cachedKey := key
		if rangeHeader := r.Header.Get("Range"); rangeHeader != "" {
			cachedKey = partialMediaKey(key, rangeHeader)
		}
		if cachedKey != "" {
			file, header, size := c.open(cachedKey, 0)
			if file != nil {
				response.Body.Close()
				response.StatusCode = http.StatusOK
				response.Status = "200 OK"
				response.Body = file
				response.ContentLength = size
				response.Header = http.Header{"Content-Type": {header.Type}, "Cache-Control": {"no-store"}}
				if header.Range != "" {
					response.StatusCode = http.StatusPartialContent
					response.Status = "206 Partial Content"
					response.Header.Set("Content-Range", header.Range)
					response.Header.Set("Accept-Ranges", "bytes")
				}
			}
		}
		return
	}
	header := cachedDataHeader{Type: response.Header.Get("Content-Type")}
	scope, _ := url.PathUnescape(response.Header.Get("X-WeQ-Cache-Scope"))
	response.Header.Del("X-WeQ-Cache-Scope")
	// 只有电脑端确认过账号/来源的资源才落盘。
	if scope != r.URL.Query().Get("weqCacheScope") ||
		!validCacheMedia(header.Type) || response.Header.Get("Content-Encoding") != "" ||
		strings.Contains(strings.ToLower(response.Header.Get("Cache-Control")), "no-store") {
		return
	}
	if response.StatusCode == http.StatusPartialContent {
		contentRange := response.Header.Get("Content-Range")
		if response.ContentLength <= 0 || !strings.HasPrefix(contentRange, "bytes ") {
			return
		}
		// 许多播放器从 bytes=0- 读取整段。完整响应可在离线时任意定位。
		if contentRange != fmt.Sprintf("bytes 0-%d/%d", response.ContentLength-1, response.ContentLength) {
			key = partialMediaKey(key, r.Header.Get("Range"))
			if key == "" {
				return
			}
			header.Range = contentRange
		}
	} else if response.StatusCode != http.StatusOK {
		return
	}
	response.Header.Set("Cache-Control", "no-store")
	generation, _ := r.Context().Value(mediaCacheGenerationKey{}).(string)
	if generation == "" {
		return
	}
	if write := c.begin(key, header, response.ContentLength, generation); write != nil {
		response.Body = &cacheMediaBody{ReadCloser: response.Body, write: write, expected: response.ContentLength}
	}
}

type mediaCacheGenerationKey struct{}

func (c *dataCache) mediaRequest(r *http.Request) *http.Request {
	if r.Method != http.MethodGet || mediaCacheKey(r.URL) == "" {
		return r
	}
	c.mu.Lock()
	generation := strconv.FormatUint(c.generation, 10)
	c.mu.Unlock()
	return r.WithContext(context.WithValue(r.Context(), mediaCacheGenerationKey{}, generation))
}

func (c *dataCache) invalidate() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.generation++
}
