// Package androidnet 为最小 Android 客户端提供用户态 TS 与受限 HTTP 请求。
package androidnet

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/net/netmon"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
)

var interfaceMu sync.RWMutex
var interfaces []netmon.Interface

var errPinnedCertificate = errors.New("computer certificate changed; pair again")

type remoteTransportError struct{ retry bool }

func (e *remoteTransportError) Error() string { return "连接失败，请检查网络及电脑状态" }

func init() {
	netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
		interfaceMu.RLock()
		defer interfaceMu.RUnlock()
		return append([]netmon.Interface(nil), interfaces...), nil
	})
}

// SetInterfaces 使用 Android Java API 的快照，避免应用 UID 被禁止访问 netlink。
func SetInterfaces(raw string) error {
	if len(raw) > 65536 {
		return errors.New("interface snapshot too large")
	}
	var input []struct {
		Name      string   `json:"name"`
		Index     int      `json:"index"`
		MTU       int      `json:"mtu"`
		Flags     int      `json:"flags"`
		Addresses []string `json:"addresses"`
	}
	if err := json.Unmarshal([]byte(raw), &input); err != nil || len(input) > 64 {
		return errors.New("invalid interfaces")
	}
	var snapshot []netmon.Interface
	for _, item := range input {
		current := netmon.Interface{Interface: &net.Interface{Name: item.Name, Index: item.Index, MTU: item.MTU, Flags: net.Flags(item.Flags)}, AltAddrs: []net.Addr{}}
		for _, value := range item.Addresses {
			ip, network, err := net.ParseCIDR(value)
			if err != nil {
				return errors.New("invalid interface address")
			}
			network.IP = ip
			current.AltAddrs = append(current.AltAddrs, network)
		}
		snapshot = append(snapshot, current)
	}
	interfaceMu.Lock()
	interfaces = snapshot
	interfaceMu.Unlock()
	return nil
}

type Client struct {
	routes         *remoteRoutes
	mu             sync.RWMutex
	server         *tsnet.Server
	http           *http.Client
	checkHTTP      *http.Client
	ctx            context.Context
	cancel         context.CancelFunc
	web            *webProxy
	directEndpoint string
}

func validDirectEndpoint(endpoint string) bool {
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		return false
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port < 1 || port > 65535 {
		return false
	}
	ip, err := netip.ParseAddr(u.Hostname())
	return err == nil && ip.Is4() && (ip.IsPrivate() || netip.MustParsePrefix("100.64.0.0/10").Contains(ip))
}

func pinnedTLS(fingerprint string) *tls.Config {
	return &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true, // 信任锚是二维码中的精确证书指纹，而非系统 CA。
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) == 0 {
				return errPinnedCertificate
			}
			digest := sha256.Sum256(state.PeerCertificates[0].Raw)
			if hex.EncodeToString(digest[:]) != fingerprint {
				return errPinnedCertificate
			}
			return nil
		}}
}

// NewDirectClient 复用系统路由（含系统 Tailscale），不会启动内嵌节点。
func NewDirectClient(endpoint, fingerprint string) (*Client, error) {
	if !validDirectEndpoint(endpoint) || !hexCredential(fingerprint) {
		return nil, errors.New("invalid direct connection")
	}
	ctx, cancel := context.WithCancel(context.Background())
	transport := &http.Transport{Proxy: nil, TLSClientConfig: pinnedTLS(fingerprint), ForceAttemptHTTP2: true, MaxIdleConns: 32, MaxIdleConnsPerHost: 8, IdleConnTimeout: 90 * time.Second, ResponseHeaderTimeout: 12 * time.Second}
	return &Client{directEndpoint: endpoint, ctx: ctx, cancel: cancel, http: &http.Client{Transport: transport, Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

func (c *Client) accepts(endpoint string) bool {
	if c.directEndpoint != "" {
		return endpoint == c.directEndpoint && validDirectEndpoint(endpoint)
	}
	return validEndpoint(endpoint)
}

// NewClient 只用于官方控制面；测试配置从独立的测试 APK 进入。
func NewClient(stateDir string) (*Client, error) { return newClient(stateDir, "") }

var authKeyPattern = regexp.MustCompile(`^tskey-auth-[A-Za-z0-9_-]{20,200}$`)

// AuthStateDir 按 Key 隔离节点，避免已登录的其他网络使入网 Key 被忽略。
func AuthStateDir(stateDir, authKey string) (string, error) {
	if !authKeyPattern.MatchString(authKey) || stateDir == "" {
		return "", errors.New("invalid enrollment key")
	}
	digest := sha256.Sum256([]byte(authKey))
	return filepath.Join(stateDir, "enrolled-"+hex.EncodeToString(digest[:])), nil
}

// NewEnrolledClient 仅使用官方控制面；调用者只在内存中传递入网凭据。
func NewEnrolledClient(stateDir, authKey string) (*Client, error) {
	if !authKeyPattern.MatchString(authKey) {
		return nil, errors.New("invalid enrollment key")
	}
	return startClient(stateDir, "", authKey)
}

// NewTestClient 的目的地址必须是回环控制面；产品界面不暴露这个入口。
func NewTestClient(stateDir, control string) (*Client, error) {
	u, err := url.Parse(control)
	if err != nil || u.Scheme != "http" || u.Hostname() != "127.0.0.1" || u.Port() == "" || u.Path != "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("invalid test control")
	}
	return newClient(stateDir, control)
}

func prepareStateDir(stateDir string) error {
	if stateDir == "" {
		return errors.New("state directory required")
	}
	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return err
	}
	// Android 的 JNI 进程没有常规 HOME/tmp；SDK 即使关闭上传仍需安全的状态目录。
	if err := os.Setenv("TS_LOGS_DIR", stateDir); err != nil {
		return err
	}
	return nil
}

func newClient(stateDir, control string) (*Client, error) {
	return startClient(stateDir, control, "")
}

func networkConfig(stateDir, control, authKey string) *tsnet.Server {
	return &tsnet.Server{Dir: stateDir, Hostname: "weq-remote-android", AuthKey: authKey, ControlURL: control, Logf: logger.Discard, UserLogf: logger.Discard}
}

func startClient(stateDir, control, authKey string) (*Client, error) {
	if err := prepareStateDir(stateDir); err != nil {
		return nil, err
	}
	envknob.SetNoLogsNoSupport()
	server := networkConfig(stateDir, control, authKey)
	if err := server.Start(); err != nil {
		_ = server.Close()
		return nil, errors.New("network start failed")
	}
	transport := &http.Transport{Proxy: nil, DialContext: server.Dial, MaxIdleConns: 32, MaxIdleConnsPerHost: 8, IdleConnTimeout: 90 * time.Second, ResponseHeaderTimeout: 12 * time.Second}
	ctx, cancel := context.WithCancel(context.Background())
	return &Client{server: server, ctx: ctx, cancel: cancel, http: &http.Client{Transport: transport, Timeout: 15 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

func (c *Client) Status() (string, error) {
	if c.routes != nil {
		return c.routes.status()
	}
	return c.statusContext(context.Background())
}

// 只有实际选用内嵌路径时，界面才保存新入网身份。
func (c *Client) UsesEmbeddedNetwork() bool {
	active := c
	if c.routes != nil {
		c.routes.mu.Lock()
		defer c.routes.mu.Unlock()
		active = c.routes.active
	}
	if active == nil {
		return false
	}
	active.mu.RLock()
	defer active.mu.RUnlock()
	return active.server != nil
}

func (c *Client) statusContext(parent context.Context) (string, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.server == nil {
		return "", errors.New("network closed")
	}
	local, err := c.server.LocalClient()
	if err != nil {
		return "", errors.New("network unavailable")
	}
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()
	status, err := local.Status(ctx)
	if err != nil {
		return "", errors.New("network status failed")
	}
	data, err := json.Marshal(struct {
		State     string       `json:"state"`
		LoginURL  string       `json:"loginURL"`
		Addresses []netip.Addr `json:"addresses"`
	}{status.BackendState, status.AuthURL, status.TailscaleIPs})
	return string(data), err
}

func validEndpoint(endpoint string) bool {
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "http" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		return false
	}
	host, port, err := net.SplitHostPort(u.Host)
	if err != nil || port == "" {
		return false
	}
	number, err := strconv.Atoi(port)
	if err != nil || number < 1 || number > 65535 {
		return false
	}
	ip, err := netip.ParseAddr(host)
	return err == nil && netip.MustParsePrefix("100.64.0.0/10").Contains(ip)
}

var claimPath = regexp.MustCompile(`^/v1/pair/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)

// Request 不提供任意网络代理：仅接受配对和只读状态路径。
func (c *Client) Request(endpoint, path, method, token, body string) (string, error) {
	if c.routes != nil {
		return c.routes.request(endpoint, path, method, token, body)
	}
	return c.requestContext(c.ctx, endpoint, path, method, token, body)
}

type connectionCheckKey struct{}

// 一轮验证的总预算覆盖所有备用入口；超时仅取消请求，不关闭 Web 或代理。
func (c *Client) CheckConnection(endpoint, token string, timeoutMillis int64, recoverRoutes bool) (string, error) {
	if timeoutMillis <= 0 {
		return "", errors.New("invalid connection timeout")
	}
	parent := c.ctx
	if c.routes != nil {
		parent = c.routes.ctx
	}
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(context.WithValue(parent, connectionCheckKey{}, true), time.Duration(timeoutMillis)*time.Millisecond)
	defer cancel()
	if c.routes != nil {
		return c.routes.checkConnection(ctx, endpoint, token, recoverRoutes)
	}
	return c.requestContext(ctx, endpoint, "/v1/status", "GET", token, "")
}

func (c *Client) requestClient(check bool) *http.Client {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.http == nil || !check {
		return c.http
	}
	if c.checkHTTP == nil {
		copy := *c.http
		copy.Timeout = 0
		if transport, ok := copy.Transport.(*http.Transport); ok {
			clone := transport.Clone()
			clone.ResponseHeaderTimeout = 0
			copy.Transport = clone
		}
		c.checkHTTP = &copy
	}
	return c.checkHTTP
}

func (c *Client) requestContext(parent context.Context, endpoint, path, method, token, body string) (string, error) {
	if parent == nil {
		parent = context.Background()
	}
	if !c.accepts(endpoint) {
		return "", errors.New("invalid tailnet endpoint")
	}
	if !(method == "POST" && path == "/v1/pair" || method == "GET" && (path == "/v1/hello" || path == "/v1/status" || claimPath.MatchString(path))) || len(body) > 4096 {
		return "", errors.New("invalid remote request")
	}
	client := c.requestClient(parent.Value(connectionCheckKey{}) == true)
	if client == nil {
		return "", errors.New("network closed")
	}
	ctx, stop := context.WithCancel(parent)
	defer stop()
	stopClosed := context.AfterFunc(c.ctx, stop)
	defer stopClosed()
	if path == "/v1/hello" {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
	}
	request, err := http.NewRequestWithContext(ctx, method, endpoint+path, strings.NewReader(body))
	if err != nil {
		return "", errors.New("request failed")
	}
	request.Header.Set("Accept", "application/json")
	if header := deviceInfoHeader(); header != "" {
		request.Header.Set("X-WeQ-Device", header)
	}
	if method == "POST" {
		request.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		if len(token) != 64 || strings.Trim(token, "0123456789abcdef") != "" {
			return "", errors.New("invalid credential")
		}
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := client.Do(request)
	if err != nil {
		return "", &remoteTransportError{retry: !errors.Is(err, errPinnedCertificate) && !errors.Is(err, context.Canceled)}
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 65537))
	if err != nil || len(data) > 65536 {
		return "", errors.New("invalid remote response")
	}
	output, err := json.Marshal(struct {
		Status int    `json:"status"`
		Body   string `json:"body"`
	}{response.StatusCode, string(data)})
	return string(output), err
}

func (c *Client) Close() {
	if c.routes != nil {
		c.routes.close()
		return
	}
	c.mu.Lock()
	server, client := c.server, c.http
	checkClient := c.checkHTTP
	c.checkHTTP = nil
	web := c.web
	c.web = nil
	c.server, c.http = nil, nil
	if c.cancel != nil {
		c.cancel()
	}
	c.mu.Unlock()
	if web != nil {
		web.close()
	}
	if client != nil {
		client.CloseIdleConnections()
	}
	if checkClient != nil {
		checkClient.CloseIdleConnections()
	}
	if server != nil {
		_ = server.Close()
	}
}
