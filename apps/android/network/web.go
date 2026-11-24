package androidnet

import (
	"errors"
	"net/url"

	"weq.local/android-net/webgateway"
)

func hexCredential(value string) bool { return webgateway.Credential(value) }

func SetWebCacheDirectory(directory string) error { return webgateway.SetWebCacheDirectory(directory) }
func SetWebStorageDirectory(directory string) error {
	return webgateway.SetWebStorageDirectory(directory)
}
func ClearWebCache() { webgateway.ClearWebCache() }
func HasCachedWebRelease(directory, token string) bool {
	return webgateway.HasCachedRelease(directory, token)
}

type WebGateway struct{ gateway *webgateway.Gateway }

func NewWebGateway(token, secret string) (*WebGateway, error) {
	gateway, err := webgateway.Open(token, secret)
	if err != nil {
		return nil, err
	}
	return &WebGateway{gateway}, nil
}

func (g *WebGateway) Origin() string   { return g.gateway.Origin() }
func (g *WebGateway) HasRelease() bool { return g.gateway.HasRelease() }
func (g *WebGateway) Close()           { g.gateway.Close() }

func (g *WebGateway) StoreImage(id, media string, body []byte) bool {
	return g.gateway.StoreImage(id, media, body)
}

func (c *Client) AttachWeb(g *WebGateway, endpoint string) error {
	return c.AttachWebRelease(g, endpoint, "")
}

func (c *Client) AttachWebRelease(g *WebGateway, endpoint, version string) error {
	return c.attachWebRelease(g, endpoint, version, false)
}

func (c *Client) AttachStartupWeb(g *WebGateway, endpoint, version string) error {
	return c.attachWebRelease(g, endpoint, version, true)
}

func (c *Client) attachWebRelease(g *WebGateway, endpoint, version string, startup bool) error {
	if g == nil {
		return errors.New("missing gateway")
	}
	if c.routes != nil {
		r := c.routes
		r.mu.Lock()
		defer r.mu.Unlock()
		if r.closed || endpoint != r.endpoints[0] || r.active == nil {
			return errors.New("invalid connection")
		}
		return r.active.attachWebRelease(g, r.endpoint, version, startup)
	}
	if !c.accepts(endpoint) {
		return errors.New("invalid web destination")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.http == nil {
		return errors.New("network closed")
	}
	target, _ := url.Parse(endpoint)
	if startup {
		g.gateway.AttachStartup(target, c.http.Transport, version)
	} else {
		g.gateway.AttachRelease(target, c.http.Transport, version)
	}
	return nil
}

// OpenWeb 保留协议夹具和连接客户端的独立代理入口。
func (c *Client) OpenWeb(endpoint, token, secret string) (string, error) {
	if c.routes != nil {
		return c.routes.openWeb(endpoint, token, secret)
	}
	if !c.accepts(endpoint) {
		return "", errors.New("invalid web destination")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.http == nil || c.web != nil {
		return "", errors.New("web view already open or network closed")
	}
	g, err := NewWebGateway(token, secret)
	if err != nil {
		return "", err
	}
	target, _ := url.Parse(endpoint)
	g.gateway.Attach(target, c.http.Transport)
	c.web = g
	return g.Origin(), nil
}

func (c *Client) CloseWeb() {
	if c.routes != nil {
		c.routes.closeWeb()
		return
	}
	c.mu.Lock()
	web := c.web
	c.web = nil
	c.mu.Unlock()
	if web != nil {
		web.Close()
	}
}

func (c *Client) HasWeb() bool {
	if c.routes != nil {
		c.routes.mu.Lock()
		defer c.routes.mu.Unlock()
		return !c.routes.closed && c.routes.active != nil && c.routes.active.HasWeb()
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.web != nil
}
