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
	endpoints []string
	open      func(context.Context, string) (*Client, error)
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
	routes := &remoteRoutes{endpoints: endpoints, clients: make(map[string]*Client)}
	routes.open = func(ctx context.Context, endpoint string) (*Client, error) {
		if strings.HasPrefix(endpoint, "https:") {
			return NewDirectClient(endpoint, fingerprint)
		}
		return openEmbedded(ctx)
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
	type candidate struct {
		endpoint string
		client   *Client
		index    int
	}
	type outcome struct {
		candidate
		err   error
		fatal bool
	}
	ctx, cancel := context.WithCancel(context.Background())
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
				raw, err := entry.client.requestContext(ctx, entry.endpoint, "/v1/hello", "GET", "", "")
				if err != nil {
					var failure *remoteTransportError
					fatal := !(errors.As(err, &failure) && failure.retry)
					results <- outcome{entry, err, fatal}
					if fatal {
						return
					}
					continue
				}
				var response struct {
					Status int
					Body   string
				}
				var hello struct {
					Product  string
					Protocol int
				}
				if json.Unmarshal([]byte(raw), &response) != nil || response.Status != 200 || json.Unmarshal([]byte(response.Body), &hello) != nil || hello.Product != "WeQ Remote" || hello.Protocol != 1 {
					results <- outcome{entry, errors.New("电脑返回了不兼容的数据"), true}
					return
				}
				results <- outcome{candidate: entry}
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
