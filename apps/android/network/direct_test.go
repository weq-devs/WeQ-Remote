package androidnet

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPinnedDirectConnection(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("a", 64) {
			t.Error("credential missing")
		}
		_, _ = io.WriteString(w, `{"online":true}`)
	}))
	defer server.Close()
	digest := sha256.Sum256(server.Certificate().Raw)
	endpoint := "https://192.168.1.8:7691"
	client, err := NewDirectClient(endpoint, hex.EncodeToString(digest[:]))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	transport := client.http.Transport.(*http.Transport)
	transport.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}
	raw, err := client.Request(endpoint, "/v1/status", "GET", strings.Repeat("a", 64), "")
	if err != nil || !strings.Contains(raw, "200") {
		t.Fatalf("pinned request failed: %s %v", raw, err)
	}
	if _, err := client.Request("https://192.168.1.9:7691", "/v1/status", "GET", strings.Repeat("a", 64), ""); err == nil {
		t.Fatal("client accepted different endpoint")
	}
	transport.CloseIdleConnections()
	transport.TLSClientConfig = pinnedTLS(strings.Repeat("b", 64))
	if _, err := client.Request(endpoint, "/v1/status", "GET", strings.Repeat("a", 64), ""); err == nil {
		t.Fatal("wrong certificate accepted")
	}
}

func TestDirectEndpointRestrictions(t *testing.T) {
	for _, value := range []string{"http://192.168.1.2:7691", "https://8.8.8.8:7691", "https://127.0.0.1:7691", "https://example.com:7691", "https://192.168.1.2:0", "https://user@192.168.1.2:7691", "https://192.168.1.2:7691/path"} {
		if _, err := NewDirectClient(value, strings.Repeat("a", 64)); err == nil {
			t.Fatalf("unsafe destination accepted: %s", value)
		}
	}
	for _, value := range []string{"https://10.0.0.2:7691", "https://172.16.0.2:7691", "https://100.64.0.2:7691"} {
		client, err := NewDirectClient(value, strings.Repeat("a", 64))
		if err != nil {
			t.Fatal(err)
		}
		client.Close()
	}
}
