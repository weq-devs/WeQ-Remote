package androidnet

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"sync"
)

var deviceInfo struct {
	sync.RWMutex
	header string
}

// SetDeviceInfo 由原生壳提供设备快照，所有入口与重连共用，不另发网络请求。
func SetDeviceInfo(raw string) error {
	if len(raw) > 1536 {
		return errors.New("device info too large")
	}
	var info struct {
		Platform   string `json:"platform"`
		Model      string `json:"model"`
		OSVersion  string `json:"osVersion"`
		AppVersion string `json:"appVersion"`
		AppBuild   string `json:"appBuild"`
	}
	if err := json.Unmarshal([]byte(raw), &info); err != nil || info.Platform != "android" {
		return errors.New("invalid device info")
	}
	for _, value := range []string{info.Model, info.OSVersion, info.AppVersion, info.AppBuild} {
		if strings.TrimSpace(value) == "" || len(value) > 128 {
			return errors.New("invalid device info field")
		}
	}
	data, err := json.Marshal(info)
	if err != nil {
		return err
	}
	deviceInfo.Lock()
	deviceInfo.header = base64.StdEncoding.EncodeToString(data)
	deviceInfo.Unlock()
	return nil
}

func deviceInfoHeader() string {
	deviceInfo.RLock()
	defer deviceInfo.RUnlock()
	return deviceInfo.header
}
