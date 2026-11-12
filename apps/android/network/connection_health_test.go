package androidnet

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestConnectionCheckBudgetOverridesLegacyClientTimeout(t *testing.T) {
	endpoint := "https://192.168.1.8:7691"
	client := &Client{ctx: context.Background(), directEndpoint: endpoint,
		http: &http.Client{Timeout: time.Millisecond, Transport: assetRoundTripFunc(func(req *http.Request) (*http.Response, error) {
			select {
			case <-req.Context().Done():
				return nil, req.Context().Err()
			case <-time.After(20 * time.Millisecond):
				return &http.Response{StatusCode: 200, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"product":"WeQ Remote","protocol":1,"scope":"status:read","online":true}`))}, nil
			}
		})}}
	if _, err := client.CheckConnection(endpoint, strings.Repeat("a", 64), 1000, false); err != nil {
		t.Fatal(err)
	}
	if client.http.Timeout != time.Millisecond {
		t.Fatal("check changed the normal request timeout")
	}
}

func TestConnectionCheckCancelsAllRoutesWithinOneBudget(t *testing.T) {
	endpoint := "https://192.168.1.8:7691"
	client, err := NewPendingMultiClient(t.TempDir(), `["`+endpoint+`","https://192.168.1.9:7691"]`, strings.Repeat("f", 64), "", "")
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	active := &Client{ctx: context.Background(), directEndpoint: endpoint}
	client.routes.active = active
	client.routes.open = func(ctx context.Context, _ string) (*Client, error) { <-ctx.Done(); return nil, ctx.Err() }
	started := time.Now()
	if _, err := client.CheckConnection(endpoint, strings.Repeat("a", 64), 30, true); err == nil {
		t.Fatal("check should time out")
	}
	if time.Since(started) > time.Second {
		t.Fatal("route selection escaped the round budget")
	}
	if client.routes.active != active || client.routes.closed {
		t.Fatal("timeout destroyed the active connection")
	}
}

func TestConnectionCheckDoesNotRelaxWebTransportTimeouts(t *testing.T) {
	client, err := NewDirectClient("https://192.168.1.8:7691", strings.Repeat("f", 64))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	check := client.requestClient(true)
	normal := client.http.Transport.(*http.Transport)
	probe := check.Transport.(*http.Transport)
	if normal.ResponseHeaderTimeout != 12*time.Second || client.http.Timeout != 15*time.Second {
		t.Fatal("health checks changed normal API or Web proxy timeouts")
	}
	if probe.ResponseHeaderTimeout != 0 || check.Timeout != 0 || probe == normal {
		t.Fatal("health checks must use their own round budget")
	}
	if client.requestClient(true) != check {
		t.Fatal("health transport was not reused")
	}
}
