package webgateway

import (
	"bytes"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const imagePath = "/_weq-remote-local/image/"
const MaxImageBytes = 2 << 20
const maxLocalImages = 4
const localImageLifetime = 5 * time.Second

type localImage struct {
	media string
	body  []byte
	timer *time.Timer
}

// StoreImage transfers the bounded, already downloaded image to the local WebView.
// The endpoint cannot initiate an upstream request.
func (g *Gateway) StoreImage(id, media string, body []byte) bool {
	if len(id) != 32 || strings.Trim(id, "0123456789abcdef") != "" ||
		len(body) == 0 || len(body) > MaxImageBytes {
		return false
	}
	switch media {
	case "image/jpeg", "image/png", "image/apng", "image/gif", "image/webp", "image/avif":
	default:
		return false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.closed || len(g.images)+g.imageReads >= maxLocalImages || g.images[id] != nil {
		return false
	}
	if g.images == nil {
		g.images = make(map[string]*localImage)
	}
	image := &localImage{media: media, body: bytes.Clone(body)}
	g.images[id] = image
	image.timer = time.AfterFunc(localImageLifetime, func() {
		g.mu.Lock()
		defer g.mu.Unlock()
		if g.images[id] == image {
			delete(g.images, id)
		}
	})
	return true
}

func (g *Gateway) serveImage(w http.ResponseWriter, r *http.Request, id string) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	g.mu.Lock()
	image := g.images[id]
	if image != nil {
		delete(g.images, id)
		image.timer.Stop()
		g.imageReads++
	}
	g.mu.Unlock()
	if image == nil {
		http.NotFound(w, r)
		return
	}
	defer func() {
		g.mu.Lock()
		g.imageReads--
		g.mu.Unlock()
	}()
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Type", image.media)
	w.Header().Set("Content-Length", strconv.Itoa(len(image.body)))
	_, _ = w.Write(image.body)
}
