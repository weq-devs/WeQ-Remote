package androidnet

import (
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
)

func TestWebOriginSurvivesRestartAndRouteChanges(t *testing.T) {
	directory := t.TempDir()
	if err := SetWebStorageDirectory(directory); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { webStorage.Lock(); webStorage.directory = ""; webStorage.Unlock() })
	token := strings.Repeat("a", 64)
	first, err := listenWebOrigin(token)
	if err != nil {
		t.Fatal(err)
	}
	address := first.Addr().String()
	if _, err := listenWebOrigin(token); err == nil {
		t.Fatal("occupied origin silently changed")
	}
	first.Close()
	// 重新设置目录模拟进程重启；不依赖 endpoint 或进程内映射。
	if err := SetWebStorageDirectory(filepath.Clean(directory)); err != nil {
		t.Fatal(err)
	}
	next, err := listenWebOrigin(token)
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	if next.Addr().String() != address {
		t.Fatal("origin changed after restart")
	}
	other, err := listenWebOrigin(strings.Repeat("b", 64))
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if other.Addr().String() == address {
		t.Fatal("authorizations share origin")
	}
	if next.Addr().(*net.TCPAddr).IP.String() != "127.0.0.1" {
		t.Fatal("not loopback")
	}
}

func TestProxyReconnectReusesOriginWithFreshLocalSecret(t *testing.T) {
	if err := SetWebStorageDirectory(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { webStorage.Lock(); webStorage.directory = ""; webStorage.Unlock() })
	token := strings.Repeat("a", 64)
	first := &Client{http: &http.Client{}}
	origin, err := first.OpenWeb("http://100.64.0.10:7691", token, strings.Repeat("b", 64))
	if err != nil {
		t.Fatal(err)
	}
	first.CloseWeb()
	second := &Client{http: &http.Client{}}
	next, err := second.OpenWeb("http://100.64.0.11:7691", token, strings.Repeat("c", 64))
	if err != nil {
		t.Fatal(err)
	}
	defer second.CloseWeb()
	if next != origin {
		t.Fatal("route change changed browser storage origin")
	}
	request, _ := http.NewRequest(http.MethodGet, next+"/", nil)
	request.AddCookie(&http.Cookie{Name: "weq_remote_local", Value: strings.Repeat("b", 64)})
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusForbidden {
		t.Fatal("previous local secret remains authorized")
	}
}

func TestWebProxyCloseBeforeServeReleasesOrigin(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	address := listener.Addr().String()
	proxy := &webProxy{server: &http.Server{}, listener: listener}
	proxy.close()
	next, err := net.Listen("tcp4", address)
	if err != nil {
		t.Fatalf("close before Serve retained the local origin: %v", err)
	}
	defer next.Close()
	// 模拟关闭之后才获得调度的 Serve，不得重新占用已释放的端口。
	if err := proxy.server.Serve(listener); err != http.ErrServerClosed {
		t.Fatalf("Serve after close: %v", err)
	}
	proxy.close()
}
