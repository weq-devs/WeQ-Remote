package androidnet

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"time"
)

type remoteRoutes struct {
	mu        sync.Mutex
	ctx       context.Context
	cancel    context.CancelFunc
	endpoints []string
	open      func(context.Context, string) (*Client, error)
	active    *Client
	endpoint  string
	clients   map[string]*Client
	closed    bool
	// 已配对设备恢复连接时，选路探测直接读取鉴权状态，结果留给首次状态请求复用。
	probeToken string
	probeRaw   string
}

// NewMultiClient 先探测路径再提交一次配对；原始 Key 不进入保存的连接资料。
// 传入已配对令牌时探测改为鉴权状态读取，避免连接时再重复核验一次。
func NewMultiClient(stateDir, rawEndpoints, fingerprint, authKey, token string) (*Client, error) {
	client, err := NewPendingMultiClient(stateDir, rawEndpoints, fingerprint, authKey, token)
	if err != nil {
		return nil, err
	}
	if err := client.ConnectRoutes(); err != nil {
		client.Close()
		return nil, err
	}
	return client, nil
}

// NewPendingMultiClient 先创建可关闭的连接句柄，让界面能取消正在进行的探测或入网。
func NewPendingMultiClient(stateDir, rawEndpoints, fingerprint, authKey, token string) (*Client, error) {
	var endpoints []string
	if err := json.Unmarshal([]byte(rawEndpoints), &endpoints); len(rawEndpoints) > 4096 || err != nil || !validRoutes(endpoints, fingerprint) {
		return nil, errors.New("invalid connection routes")
	}
	var embedded *Client
	openEmbedded := func(ctx context.Context) (*Client, error) {
		var err error
		if embedded == nil {
			if authKey != "" {
				embedded, err = NewEnrolledClient(stateDir, authKey)
			} else {
				embedded, err = NewClient(stateDir)
			}
		}
		if err != nil {
			return nil, err
		}
		deadline := time.Now().Add(45 * time.Second)
		for time.Now().Before(deadline) {
			raw, err := embedded.statusContext(ctx)
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
			select {
			case <-ctx.Done():
				return embedded, ctx.Err()
			case <-time.After(500 * time.Millisecond):
			}
		}
		return embedded, errors.New("Tailscale 入网未完成，请重新生成包含 Key 的配对码")
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
	}
	routes := &remoteRoutes{endpoints: endpoints, clients: make(map[string]*Client), probeToken: token}
	routes.ctx, routes.cancel = context.WithCancel(context.Background())
	routes.open = func(ctx context.Context, endpoint string) (*Client, error) {
		if strings.HasPrefix(endpoint, "https:") {
			return NewDirectClient(endpoint, fingerprint)
		}
		return openEmbedded(ctx)
	}
	return &Client{routes: routes}, nil
}

func (c *Client) ConnectRoutes() error {
	if c.routes == nil {
		return errors.New("not a multi-route connection")
	}
	c.routes.mu.Lock()
	defer c.routes.mu.Unlock()
	return c.routes.selectRoute()
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
	parent := r.ctx
	if parent == nil {
		parent = context.Background()
	}
	return r.selectRouteContext(parent)
}

func (r *remoteRoutes) selectRouteContext(parent context.Context) error {
	if r.closed {
		return errors.New("connection closed")
	}
	type candidate struct {
		endpoint string
		client   *Client
		index    int
	}
	type outcome struct {
		candidate
		err      error
		fatal    bool
		probeRaw string
	}
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	var workers [][]candidate
	var embedded []candidate
	for index, endpoint := range r.endpoints {
		entry := candidate{endpoint, r.clients[endpoint], index}
		if strings.HasPrefix(endpoint, "http:") {
			embedded = append(embedded, entry)
		} else {
			workers = append(workers, []candidate{entry})
		}
	}
	if len(embedded) > 0 {
		workers = append(workers, embedded)
	}
	results := make(chan outcome, len(r.endpoints))
	var pending sync.WaitGroup
	// 内嵌路径共用一个 worker，其他地址错峰探测；只读探测不消费邀请。
	for _, worker := range workers {
		pending.Add(1)
		go func(entries []candidate) {
			defer pending.Done()
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Duration(entries[0].index) * 150 * time.Millisecond):
			}
			for _, entry := range entries {
				if ctx.Err() != nil {
					return
				}
				var err error
				if entry.client == nil {
					entry.client, err = r.open(ctx, entry.endpoint)
					if err != nil {
						results <- outcome{candidate: entry, err: err}
						continue
					}
				}
				// 已配对设备用鉴权状态探测；未批准的设备只能读 hello。
				path, token := "/v1/hello", ""
				if r.probeToken != "" {
					path, token = "/v1/status", r.probeToken
				}
				raw, err := entry.client.requestContext(ctx, entry.endpoint, path, "GET", token, "")
				if err != nil {
					var failure *remoteTransportError
					fatal := !(errors.As(err, &failure) && failure.retry)
					results <- outcome{candidate: entry, err: err, fatal: fatal}
					if fatal {
						return
					}
					continue
				}
				var response struct {
					Status int
					Body   string
				}
				var reply struct {
					Product  string
					Protocol int
					Scope    string
					Online   bool
				}
				if json.Unmarshal([]byte(raw), &response) != nil {
					results <- outcome{candidate: entry, err: errors.New("电脑返回了不兼容的数据"), fatal: true}
					return
				}
				if response.Status == 401 {
					results <- outcome{candidate: entry, err: errors.New("设备未授权或授权已被撤销，请重新配对"), fatal: true}
					return
				}
				if response.Status != 200 || json.Unmarshal([]byte(response.Body), &reply) != nil || reply.Product != "WeQ Remote" || reply.Protocol != 1 {
					results <- outcome{candidate: entry, err: errors.New("电脑返回了不兼容的数据"), fatal: true}
					return
				}
				probeRaw := ""
				if path == "/v1/status" {
					if reply.Scope != "status:read" || !reply.Online {
						results <- outcome{candidate: entry, err: errors.New("电脑返回了不兼容的数据"), fatal: true}
						return
					}
					// 选路成功的这次状态读取就是本次连接的核验，留给首次状态请求直接使用。
					probeRaw = raw
				}
				results <- outcome{candidate: entry, probeRaw: probeRaw}
				return
			}
		}(worker)
	}
	go func() { pending.Wait(); close(results) }()
	var winner *candidate
	failure := errors.New("无法连接电脑，请检查局域网或 Tailscale 连接")
	decided := false
	for result := range results {
		if result.client != nil {
			r.clients[result.endpoint] = result.client
		}
		if decided {
			continue
		}
		if result.err == nil {
			selected := result.candidate
			winner = &selected
			r.probeRaw = result.probeRaw
			decided = true
			cancel()
		} else if result.fatal {
			failure = result.err
			decided = true
			cancel()
		}
	}
	if winner == nil {
		return failure
	}
	if r.active != nil && r.active != winner.client {
		r.active.CloseWeb()
	}
	r.active, r.endpoint = winner.client, winner.endpoint
	return nil
}

func (r *remoteRoutes) checkConnection(ctx context.Context, endpoint, token string, recoverRoutes bool) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || endpoint != r.endpoints[0] || r.active == nil {
		return "", errors.New("invalid connection")
	}
	if recoverRoutes {
		if err := r.selectRouteContext(ctx); err != nil {
			return "", err
		}
	}
	if cached, ok := r.takeProbe("/v1/status", "GET"); ok {
		return cached, nil
	}
	return r.active.requestContext(ctx, r.endpoint, "/v1/status", "GET", token, "")
}

func (r *remoteRoutes) request(endpoint, path, method, token, body string) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || endpoint != r.endpoints[0] || r.active == nil {
		return "", errors.New("invalid connection")
	}
	if cached, ok := r.takeProbe(path, method); ok {
		return cached, nil
	}
	parent := r.ctx
	if parent == nil {
		parent = context.Background()
	}
	result, err := r.active.requestContext(parent, r.endpoint, path, method, token, body)
	// POST 可能已到达电脑，不能在另一条路径重发消费一次性邀请。
	var failure *remoteTransportError
	if err != nil && method == "GET" && errors.As(err, &failure) && failure.retry {
		if err = r.selectRoute(); err == nil {
			if cached, ok := r.takeProbe(path, method); ok {
				return cached, nil
			}
			return r.active.requestContext(parent, r.endpoint, path, method, token, body)
		}
	}
	return result, err
}

// takeProbe 只把选路时已取得的鉴权状态交给紧随其后的首次状态读取；其他请求立即作废这份缓存。
func (r *remoteRoutes) takeProbe(path, method string) (string, bool) {
	if r.probeRaw == "" {
		return "", false
	}
	cached := r.probeRaw
	r.probeRaw = ""
	if method == "GET" && path == "/v1/status" {
		return cached, true
	}
	return "", false
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
	if r.cancel != nil {
		r.cancel()
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closed = true
	for _, client := range r.clients {
		client.Close()
	}
	r.clients = nil
	r.active = nil
}
