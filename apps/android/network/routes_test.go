package androidnet

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestFastRouteDoesNotWaitForBlackholedFirstAddress(t *testing.T) {
	slow, fast := "https://192.168.1.8:7691", "https://100.64.0.10:7692"
	routes := &remoteRoutes{endpoints: []string{slow, fast}, clients: make(map[string]*Client)}
	routes.open = func(_ context.Context, endpoint string) (*Client, error) {
		ctx, cancel := context.WithCancel(context.Background())
		return &Client{directEndpoint: endpoint, ctx: ctx, cancel: cancel, http: &http.Client{Transport: assetRoundTripFunc(func(req *http.Request) (*http.Response, error) {
			if endpoint == slow {
				select {
				case <-req.Context().Done():
					return nil, req.Context().Err()
				case <-time.After(2 * time.Second):
					return nil, errors.New("offline")
				}
			}
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"product":"WeQ Remote","protocol":1}`)), Header: make(http.Header)}, nil
		})}}, nil
	}
	defer routes.close()
	start := time.Now()
	if err := routes.selectRoute(); err != nil {
		t.Fatal(err)
	}
	if routes.endpoint != fast || time.Since(start) >= time.Second {
		t.Fatal("fast route was blocked by the first address", time.Since(start))
	}
}

func TestDirectRouteDoesNotWaitForEmbeddedEnrollment(t *testing.T) {
	embedded, direct := "http://100.64.0.10:7691", "https://192.168.1.8:7691"
	var canceled atomic.Bool
	routes := &remoteRoutes{endpoints: []string{embedded, direct}, clients: make(map[string]*Client)}
	routes.open = func(ctx context.Context, endpoint string) (*Client, error) {
		if endpoint == embedded {
			<-ctx.Done()
			canceled.Store(true)
			return nil, ctx.Err()
		}
		clientCtx, cancel := context.WithCancel(context.Background())
		return &Client{directEndpoint: endpoint, ctx: clientCtx, cancel: cancel, http: &http.Client{Transport: assetRoundTripFunc(func(*http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"product":"WeQ Remote","protocol":1}`)), Header: make(http.Header)}, nil
		})}}, nil
	}
	defer routes.close()
	start := time.Now()
	if err := routes.selectRoute(); err != nil {
		t.Fatal(err)
	}
	if routes.endpoint != direct || !canceled.Load() || time.Since(start) >= time.Second {
		t.Fatal("direct route waited for enrollment or did not cancel its worker")
	}
	if (&Client{routes: routes}).UsesEmbeddedNetwork() {
		t.Fatal("direct connection must not replace the saved embedded identity")
	}
}

func TestMultiRouteUsesPinnedTLSBeforeSinglePairPost(t *testing.T) {
	var posts atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if req.URL.Path == "/v1/pair" {
			posts.Add(1)
			w.WriteHeader(201)
		}
		_, _ = io.WriteString(w, `{"product":"WeQ Remote","protocol":1}`)
	}))
	defer server.Close()
	digest := sha256.Sum256(server.Certificate().Raw)
	pin := hex.EncodeToString(digest[:])
	lan, second := "https://192.168.1.8:7691", "https://192.168.2.8:7691"
	for _, badPin := range []bool{false, true} {
		routes := &remoteRoutes{endpoints: []string{lan, second}, clients: make(map[string]*Client)}
		routes.open = func(_ context.Context, endpoint string) (*Client, error) {
			fingerprint := pin
			if badPin {
				fingerprint = strings.Repeat("0", 64)
			}
			client, err := NewDirectClient(endpoint, fingerprint)
			if err != nil {
				return nil, err
			}
			client.http.Transport.(*http.Transport).DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
			}
			return client, nil
		}
		err := routes.selectRoute()
		if badPin {
			if err == nil {
				t.Fatal("certificate mismatch must stop route selection")
			}
		} else {
			if err != nil {
				t.Fatal(err)
			}
			if _, err := routes.request(lan, "/v1/pair", "POST", "", `{}`); err != nil {
				t.Fatal(err)
			}
			if posts.Load() != 1 {
				t.Fatal("pair request was repeated")
			}
		}
		routes.close()
	}
}

func TestMultiRouteProbeAndReconnect(t *testing.T) {
	lan, tail := "https://192.168.1.8:7691", "http://100.64.0.10:7691"
	down := map[string]bool{lan: true}
	var requests []string
	var requestsMu sync.Mutex
	deny := false
	routes := &remoteRoutes{endpoints: []string{lan, tail}, clients: make(map[string]*Client)}
	routes.open = func(_ context.Context, endpoint string) (*Client, error) {
		client := &Client{ctx: context.Background(), http: &http.Client{Transport: assetRoundTripFunc(func(req *http.Request) (*http.Response, error) {
			requestsMu.Lock()
			requests = append(requests, req.Method+" "+endpoint+req.URL.Path)
			requestsMu.Unlock()
			if down[endpoint] {
				return nil, errors.New("offline")
			}
			status, body := 200, `{"product":"WeQ Remote","protocol":1}`
			if req.URL.Path != "/v1/hello" && deny {
				status, body = 401, `{}`
			}
			return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
		})}}
		if strings.HasPrefix(endpoint, "https:") {
			client.directEndpoint = endpoint
		}
		return client, nil
	}
	defer routes.close()
	if err := routes.selectRoute(); err != nil {
		t.Fatal(err)
	}
	if routes.endpoint != tail {
		t.Fatal("did not fall back to embedded route")
	}
	client := &Client{routes: routes}
	if _, err := client.OpenWeb(lan, strings.Repeat("a", 64), strings.Repeat("b", 64)); err != nil || !client.HasWeb() {
		t.Fatal("active route did not open a Web proxy", err)
	}
	if _, err := routes.request(lan, "/v1/pair", "POST", "", `{}`); err != nil {
		t.Fatal(err)
	}
	posts := 0
	for _, request := range requests {
		if strings.HasPrefix(request, "POST ") {
			posts++
		}
	}
	if posts != 1 {
		t.Fatal("pairing invitation was submitted more than once")
	}
	if _, err := routes.request(lan, "/v1/status", "GET", strings.Repeat("a", 64), ""); err != nil || !client.HasWeb() {
		t.Fatal("same-route foreground verification discarded the Web proxy", err)
	}
	down[lan], down[tail] = false, true
	if _, err := routes.request(lan, "/v1/status", "GET", strings.Repeat("a", 64), ""); err != nil {
		t.Fatal(err)
	}
	if routes.endpoint != lan {
		t.Fatal("GET did not reconnect through LAN")
	}
	if client.HasWeb() {
		t.Fatal("route change must report that the old Web proxy needs replacing")
	}
	deny = true
	before := len(requests)
	raw, err := routes.request(lan, "/v1/status", "GET", strings.Repeat("a", 64), "")
	var response struct {
		Status int `json:"status"`
	}
	if err != nil || json.Unmarshal([]byte(raw), &response) != nil || response.Status != 401 || len(requests) != before+1 {
		t.Fatal("authorization failure must not trigger route fallback")
	}
	down[lan] = true
	before = len(requests)
	if _, err := routes.request(lan, "/v1/pair", "POST", "", `{}`); err == nil {
		t.Fatal("offline pairing unexpectedly succeeded")
	}
	if len(requests) != before+1 {
		t.Fatal("POST was retried after an ambiguous network failure")
	}
}

func TestMultiRoutesRejectInvalidDestinationsBeforeStartingNetwork(t *testing.T) {
	pin := strings.Repeat("f", 64)
	for _, endpoints := range [][]string{nil, {"http://192.168.1.8:80"}, {"https://8.8.8.8:80"}, {"https://192.168.1.8:7691", "https://192.168.1.8:7691"}} {
		raw, _ := json.Marshal(endpoints)
		if _, err := NewMultiClient(t.TempDir(), string(raw), pin, ""); err == nil {
			t.Fatal("invalid routes accepted")
		}
	}
}
