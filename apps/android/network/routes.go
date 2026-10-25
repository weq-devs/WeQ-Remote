package androidnet

import (
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"time"
)

type remoteRoutes struct {
	mu        sync.Mutex
	endpoints []string
	open      func(string) (*Client, error)
	active    *Client
	endpoint  string
	clients   map[string]*Client
	closed    bool
}

// NewMultiClient 先探测路径再提交一次配对；原始 Key 不进入保存的连接资料。
func NewMultiClient(stateDir, rawEndpoints, fingerprint, authKey string) (*Client, error) {
	var endpoints []string
	if err := json.Unmarshal([]byte(rawEndpoints), &endpoints); len(rawEndpoints) > 4096 || err != nil || !validRoutes(endpoints, fingerprint) {
		return nil, errors.New("invalid connection routes")
	}
	var embedded *Client
	openEmbedded := func() (*Client, error) {
		if embedded != nil {
			return embedded, nil
		}
		var err error
		if authKey != "" {
			embedded, err = NewEnrolledClient(stateDir, authKey)
		} else {
			embedded, err = NewClient(stateDir)
		}
		if err != nil {
			return nil, err
		}
		deadline := time.Now().Add(45 * time.Second)
		for time.Now().Before(deadline) {
			raw, err := embedded.Status()
			var status struct {
				State    string `json:"state"`
				LoginURL string `json:"loginURL"`
			}
			if err == nil && json.Unmarshal([]byte(raw), &status) == nil {
				if status.State == "Running" {
					return embedded, nil
				}
				if status.LoginURL != "" || status.State == "NeedsMachineAuth" {
					break
				}
			}
			time.Sleep(500 * time.Millisecond)
		}
		embedded.Close()
		embedded = nil
		return nil, errors.New("Tailscale 入网未完成，请重新生成包含 Key 的配对码")
	}
	if authKey != "" {
		if !authKeyPattern.MatchString(authKey) {
			return nil, errors.New("invalid enrollment key")
		}
		hasEmbedded := false
		for _, endpoint := range endpoints {
			if validEndpoint(endpoint) {
				hasEmbedded = true
			}
		}
		if !hasEmbedded {
			return nil, errors.New("missing embedded connection route")
		}
		if _, err := openEmbedded(); err != nil {
			return nil, err
		}
		authKey = ""
	}
	routes := &remoteRoutes{endpoints: endpoints, clients: make(map[string]*Client)}
	routes.open = func(endpoint string) (*Client, error) {
		if strings.HasPrefix(endpoint, "https:") {
			return NewDirectClient(endpoint, fingerprint)
		}
		return openEmbedded()
	}
	if embedded != nil {
		routes.clients["embedded"] = embedded
	}
	if err := routes.selectRoute(); err != nil {
		routes.close()
		return nil, err
	}
	return &Client{routes: routes}, nil
}

func validRoutes(endpoints []string, fingerprint string) bool {
	if len(endpoints) == 0 || len(endpoints) > 8 || !hexCredential(fingerprint) {
		return false
	}
	seen := make(map[string]bool)
	for _, endpoint := range endpoints {
		if seen[endpoint] || !(validDirectEndpoint(endpoint) || validEndpoint(endpoint)) {
			return false
		}
		seen[endpoint] = true
	}
	return true
}

func (r *remoteRoutes) selectRoute() error {
	if r.closed {
		return errors.New("connection closed")
	}
	for _, endpoint := range r.endpoints {
		client := r.clients[endpoint]
		if client == nil {
			var err error
			client, err = r.open(endpoint)
			if err != nil {
				continue
			}
			r.clients[endpoint] = client
		}
		raw, err := client.Request(endpoint, "/v1/hello", "GET", "", "")
		if err != nil {
			var failure *remoteTransportError
			if errors.As(err, &failure) && failure.retry {
				continue
			}
			return err
		}
		var response struct {
			Status int    `json:"status"`
			Body   string `json:"body"`
		}
		var hello struct {
			Product  string `json:"product"`
			Protocol int    `json:"protocol"`
		}
		if json.Unmarshal([]byte(raw), &response) != nil || response.Status != 200 || json.Unmarshal([]byte(response.Body), &hello) != nil || hello.Product != "WeQ Remote" || hello.Protocol != 1 {
			return errors.New("电脑返回了不兼容的数据")
		}
		if r.active != nil && r.active != client {
			r.active.CloseWeb()
		}
		r.active, r.endpoint = client, endpoint
		return nil
	}
	return errors.New("无法连接电脑，请检查局域网或 Tailscale 连接")
}

func (r *remoteRoutes) request(endpoint, path, method, token, body string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || endpoint != r.endpoints[0] || r.active == nil {
		return "", errors.New("invalid connection")
	}
	result, err := r.active.Request(r.endpoint, path, method, token, body)
	// POST 可能已到达电脑，不能在另一条路径重发消费一次性邀请。
	var failure *remoteTransportError
	if err != nil && method == "GET" && errors.As(err, &failure) && failure.retry {
		if err = r.selectRoute(); err == nil {
			return r.active.Request(r.endpoint, path, method, token, body)
		}
	}
	return result, err
}

func (r *remoteRoutes) openWeb(endpoint, token, secret string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || endpoint != r.endpoints[0] || r.active == nil {
		return "", errors.New("invalid connection")
	}
	return r.active.OpenWeb(r.endpoint, token, secret)
}

func (r *remoteRoutes) closeWeb() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, client := range r.clients {
		client.CloseWeb()
	}
}

func (r *remoteRoutes) status() (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.active == nil {
		return "", errors.New("connection closed")
	}
	return `{"state":"Running","loginURL":""}`, nil
}

func (r *remoteRoutes) close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closed = true
	for _, client := range r.clients {
		client.Close()
	}
	r.clients = nil
	r.active = nil
}
