package androidnet

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

var webStorage struct {
	sync.Mutex
	directory string
}

// SetWebStorageDirectory 使用私有 no-backup 目录保存授权对应的网页来源，不存令牌。
func SetWebStorageDirectory(directory string) error {
	if !filepath.IsAbs(directory) {
		return os.ErrInvalid
	}
	webStorage.Lock()
	defer webStorage.Unlock()
	webStorage.directory = directory
	return os.MkdirAll(directory, 0700)
}

func listenWebOrigin(token string) (net.Listener, error) {
	webStorage.Lock()
	defer webStorage.Unlock()
	if webStorage.directory == "" {
		return net.Listen("tcp4", "127.0.0.1:0")
	}
	digest := sha256.Sum256([]byte(token))
	path := filepath.Join(webStorage.directory, hex.EncodeToString(digest[:])+".port")
	data, err := os.ReadFile(path)
	if err == nil {
		port, parseErr := strconv.Atoi(strings.TrimSpace(string(data)))
		if parseErr != nil || port < 1024 || port > 65535 {
			return nil, errors.New("invalid saved web port")
		}
		// 已用来源不可静默改端口，否则持久存储会变成另一份。
		return net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
	}
	if !os.IsNotExist(err) {
		return nil, err
	}
	// 保存过的其他授权端口即使当前空闲，也不能分配给另一台电脑。
	used := make(map[int]bool)
	entries, err := os.ReadDir(webStorage.directory)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) != ".port" {
			continue
		}
		value, readErr := os.ReadFile(filepath.Join(webStorage.directory, entry.Name()))
		if readErr != nil {
			return nil, readErr
		}
		port, _ := strconv.Atoi(strings.TrimSpace(string(value)))
		used[port] = true
	}
	for attempt := 0; attempt < 64; attempt++ {
		listener, listenErr := net.Listen("tcp4", "127.0.0.1:0")
		if listenErr != nil {
			return nil, listenErr
		}
		port := listener.Addr().(*net.TCPAddr).Port
		if used[port] {
			listener.Close()
			continue
		}
		file, createErr := os.CreateTemp(webStorage.directory, ".port-")
		if createErr != nil {
			listener.Close()
			return nil, createErr
		}
		name := file.Name()
		_, writeErr := file.WriteString(strconv.Itoa(port))
		closeErr := file.Close()
		if writeErr == nil {
			writeErr = closeErr
		}
		if writeErr == nil {
			writeErr = os.Rename(name, path)
		}
		_ = os.Remove(name)
		if writeErr != nil {
			listener.Close()
			return nil, writeErr
		}
		return listener, nil
	}
	return nil, errors.New("no unused web origin available")
}
