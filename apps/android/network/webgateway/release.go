package webgateway

import (
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"html"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const releaseBudget = 32 << 20
const resourceLimit = 12 << 20
const releaseCookie = "weq_remote_release"
const updatePath = "/_weq-remote-local/release"

const offlineMarker = `<meta name="weq-remote-offline" content="1">`

var startupManifest = regexp.MustCompile(`<meta name="weq-startup-resources" content=(?:"([^"]+)"|'([^']+)')`)
var offlineManifest = regexp.MustCompile(`<meta name="weq-offline-bundle" content=(?:"([^"]+)"|'([^']+)')`)
var assetPath = regexp.MustCompile(`^/assets/[a-zA-Z0-9_.-]+\.(?:js|css)$`)

func releaseAsset(path string) bool {
	return assetPath.MatchString(path) || path == "/startup-theme.js" ||
		path == "/bundledDevClient.mjs" || path == "/@rolldown/experimental-runtime.mjs"
}

func releaseDirectory(token string) string {
	sharedWebAssets.Lock()
	defer sharedWebAssets.Unlock()
	if sharedWebAssets.directory == "" {
		return ""
	}
	key := sha256.Sum256([]byte("weq-web-release\n" + token))
	return filepath.Join(sharedWebAssets.directory, "releases", hex.EncodeToString(key[:]))
}

func readRelease(directory string) string {
	if directory == "" {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(directory, "current"))
	if err != nil || !Credential(string(data)) {
		return ""
	}
	if _, err := os.Stat(filepath.Join(directory, string(data), "index.html")); err != nil {
		return ""
	}
	return string(data)
}

func (g *Gateway) release() string { return g.currentRelease.Load().(string) }

func (g *Gateway) HasRelease() bool { return g.release() != "" }

func (g *Gateway) serveRelease(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return false
	}
	version := g.release()
	path := r.URL.Path
	switch {
	case path == updatePath:
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("X-WeQ-Local-Release", "1")
		_, _ = io.WriteString(w, version)
		go g.checkRelease()
		return true
	case version == "":
		return false
	case path == "/":
		path = "/index.html"
	case !releaseAsset(path):
		return false
	}
	if path != "/index.html" && !hashedWebCode.MatchString(path) {
		// 打包开发版的入口和运行时有固定 URL，按文档版本读取，避免切换时混用。
		if cookie, err := r.Cookie(releaseCookie); err == nil && Credential(cookie.Value) {
			version = cookie.Value
		}
	}
	file, err := os.Open(filepath.Join(g.releases, version, path))
	if err != nil && hashedWebCode.MatchString(path) {
		// 切换期间仍在运行的旧页面可以继续读取原来的哈希分包。
		entries, _ := os.ReadDir(g.releases)
		for _, candidate := range entries {
			if candidate.Name() == version || !Credential(candidate.Name()) {
				continue
			}
			file, err = os.Open(filepath.Join(g.releases, candidate.Name(), path))
			if err == nil {
				break
			}
		}
	}
	if err != nil {
		return false
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return false
	}
	g.secure(w.Header())
	w.Header().Set("Server-Timing", `weq-remote-source;desc="cache"`)
	media := mime.TypeByExtension(filepath.Ext(path))
	if scriptResource(path) {
		media = "text/javascript; charset=utf-8"
	}
	if !hashedWebCode.MatchString(path) {
		w.Header().Set("Cache-Control", "no-store")
	}
	if media != "" {
		w.Header().Set("Content-Type", media)
	}
	if path == "/index.html" {
		w.Header().Set("Cache-Control", "no-store")
		// 版本号随当前文档一起发布，避免更新完成早于网页脚本初始化时漏掉切换。
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		http.SetCookie(w, &http.Cookie{Name: releaseCookie, Value: version, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode})
		body, err := io.ReadAll(io.LimitReader(file, 2<<20))
		if err != nil {
			http.Error(w, "Web cache unavailable", 500)
			return true
		}
		body = []byte(strings.Replace(string(body), "<head>", `<head><meta name="weq-local-web-release" content="`+version+`">`, 1))
		if r.Method != http.MethodHead {
			_, _ = w.Write(body)
		}
	} else {
		http.ServeContent(w, r, path, info.ModTime(), file)
	}
	return true
}

func (g *Gateway) checkRelease() {
	g.mu.Lock()
	target, transport, code, done := g.target, g.assets, g.code, g.routeDone
	g.mu.Unlock()
	if target != nil {
		g.refreshRelease(target, transport, code, done, false)
	}
}

func (g *Gateway) refreshRelease(target *url.URL, transport *http.Transport, code *webAssetTransport, routeDone chan struct{}, attach bool) {
	if g.releases == "" || transport == nil {
		return
	}
	if attach {
		g.releaseMu.Lock()
	} else if !g.releaseMu.TryLock() {
		return
	}
	defer g.releaseMu.Unlock()
	select {
	case <-routeDone:
		return
	default:
	}
	if g.lastReleaseRoute == routeDone && time.Since(g.lastReleaseCheck) < 15*time.Second {
		return
	}
	g.lastReleaseRoute, g.lastReleaseCheck = routeDone, time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	go func() {
		select {
		case <-ctx.Done():
		case <-routeDone:
			cancel()
		}
	}()
	keepRedirect := func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	client := &http.Client{Transport: transport, CheckRedirect: keepRedirect}
	codeClient := &http.Client{Transport: code, CheckRedirect: keepRedirect}
	get := func(path string, limit int64) ([]byte, string, error) {
		endpoint := target.ResolveReference(&url.URL{Path: path})
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
		if err != nil {
			return nil, "", err
		}
		req.Header.Set("Authorization", "Bearer "+g.token)
		req.Header.Set("User-Agent", "WeQRemote")
		resourceClient := client
		if path == "/" {
			req.Header.Set("Accept", "text/html")
		} else if hashedWebCode.MatchString(path) {
			// 与 WebView 共用 gzip 分包，落盘的完整网页版本仍使用解压后的代码。
			req.Header.Set("Accept-Encoding", "gzip")
			resourceClient = codeClient
		}
		response, err := resourceClient.Do(req)
		if err != nil {
			return nil, "", err
		}
		defer response.Body.Close()
		if response.StatusCode != 200 {
			return nil, "", errors.New("resource unavailable")
		}
		var body io.Reader = response.Body
		if strings.EqualFold(response.Header.Get("Content-Encoding"), "gzip") {
			compressed, err := gzip.NewReader(body)
			if err != nil {
				return nil, "", err
			}
			defer compressed.Close()
			body = compressed
		}
		data, err := io.ReadAll(io.LimitReader(body, limit+1))
		if err != nil || len(data) == 0 || int64(len(data)) > limit {
			return nil, "", errors.New("invalid web resource size")
		}
		return data, response.Header.Get("Content-Type"), nil
	}

	shell, contentType, err := get("/", 2<<20)
	if err != nil || !strings.HasPrefix(contentType, "text/html") || !strings.Contains(string(shell), offlineMarker) {
		return
	}
	var manifest struct {
		Version   int
		Resources []struct{ Path string }
	}
	match := offlineManifest.FindSubmatch(shell)
	if match == nil {
		match = startupManifest.FindSubmatch(shell)
	}
	if match == nil || json.Unmarshal([]byte(html.UnescapeString(string(match[1])+string(match[2]))), &manifest) != nil ||
		manifest.Version != 1 || len(manifest.Resources) == 0 || len(manifest.Resources) > 1024 {
		return
	}
	digest := sha256.Sum256(shell)
	version := hex.EncodeToString(digest[:])
	previous := g.release()
	if version == previous {
		return
	}
	if os.MkdirAll(g.releases, 0700) != nil {
		return
	}
	staging, err := os.MkdirTemp(g.releases, ".staging-")
	if err != nil {
		return
	}
	defer os.RemoveAll(staging)
	if os.Mkdir(filepath.Join(staging, "assets"), 0700) != nil ||
		os.WriteFile(filepath.Join(staging, "index.html"), shell, 0600) != nil {
		return
	}

	paths := map[string]bool{"/startup-theme.js": true}
	for _, resource := range manifest.Resources {
		if !releaseAsset(resource.Path) {
			return
		}
		paths[resource.Path] = true
	}
	var mu sync.Mutex
	total := len(shell)
	var tasks sync.WaitGroup
	queue := make(chan string, len(paths))
	for path := range paths {
		queue <- path
	}
	close(queue)
	for range 4 {
		tasks.Go(func() {
			for path := range queue {
				if ctx.Err() != nil {
					return
				}
				destination := filepath.Join(staging, path)
				if os.MkdirAll(filepath.Dir(destination), 0700) != nil {
					cancel()
					return
				}
				size := 0
				// 文件名带内容哈希的分包从上一套完整资源直接复用。
				if previous != "" && hashedWebCode.MatchString(path) {
					source := filepath.Join(g.releases, previous, path)
					if stat, err := os.Stat(source); err == nil && os.Link(source, destination) == nil {
						size = int(stat.Size())
					}
				}
				if size == 0 {
					body, media, err := get(path, resourceLimit)
					valid := strings.HasSuffix(path, ".css") && strings.HasPrefix(media, "text/css") ||
						scriptResource(path) && (strings.HasPrefix(media, "text/javascript") || strings.HasPrefix(media, "application/javascript"))
					if err != nil || !valid || os.WriteFile(destination, body, 0600) != nil {
						cancel()
						return
					}
					size = len(body)
				}
				mu.Lock()
				total += size
				over := total > releaseBudget
				mu.Unlock()
				if over {
					cancel()
					return
				}
			}
		})
	}
	tasks.Wait()
	// 发布与撤销互斥。任一资源失败时继续使用上一套完整页面。
	g.mu.Lock()
	defer g.mu.Unlock()
	if ctx.Err() != nil || g.routeDone != routeDone {
		return
	}
	destination := filepath.Join(g.releases, version)
	_ = os.RemoveAll(destination)
	if os.Rename(staging, destination) != nil {
		return
	}
	pointer := filepath.Join(g.releases, ".current")
	if os.WriteFile(pointer, []byte(version), 0600) != nil ||
		os.Rename(pointer, filepath.Join(g.releases, "current")) != nil {
		return
	}
	g.currentRelease.Store(version)
	entries, _ := os.ReadDir(g.releases)
	for _, entry := range entries {
		if entry.IsDir() && entry.Name() != version && entry.Name() != previous {
			_ = os.RemoveAll(filepath.Join(g.releases, entry.Name()))
		}
	}
}

func scriptResource(path string) bool {
	return strings.HasSuffix(path, ".js") || strings.HasSuffix(path, ".mjs")
}
