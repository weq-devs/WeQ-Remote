package androidnet

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDeviceInfoOnRealProtocolRequest(t *testing.T) {
	raw := `{"platform":"android","model":"Test Phone","osVersion":"16","appVersion":"1.0.0b3","appBuild":"9"}`
	if err := SetDeviceInfo(raw); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { deviceInfo.Lock(); deviceInfo.header = ""; deviceInfo.Unlock() })
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, err := base64.StdEncoding.DecodeString(r.Header.Get("X-WeQ-Device"))
		if err != nil {
			t.Error(err)
		}
		var info map[string]string
		if json.Unmarshal(data, &info) != nil || len(info) != 5 || info["model"] != "Test Phone" || info["appBuild"] != "9" {
			t.Errorf("unexpected device info: %s", data)
		}
		if r.URL.Path != "/v1/status" || r.Header.Get("Authorization") != "Bearer "+strings.Repeat("a", 64) {
			t.Error("protocol changed")
		}
		_, _ = w.Write([]byte(`{"online":true}`))
	}))
	defer server.Close()
	digest := sha256.Sum256(server.Certificate().Raw)
	endpoint := "https://192.168.1.8:7691"
	client, err := NewDirectClient(endpoint, hex.EncodeToString(digest[:]))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	client.http.Transport.(*http.Transport).DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}
	if _, err := client.Request(endpoint, "/v1/status", "GET", strings.Repeat("a", 64), ""); err != nil {
		t.Fatal(err)
	}
	previous := deviceInfoHeader()
	for _, invalid := range []string{"{", `{}`, strings.Repeat("a", 1537), strings.Replace(raw, "Test Phone", "", 1)} {
		if SetDeviceInfo(invalid) == nil {
			t.Fatal("invalid info accepted")
		}
		if deviceInfoHeader() != previous {
			t.Fatal("invalid info replaced valid snapshot")
		}
	}
}
