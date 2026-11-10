package androidnet

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sort"
)

const webAssetDiskBudget = 48 << 20

// SetWebCacheDirectory 由 Android 私有 cacheDir 提供；目录内只存 immutable 代码，不保存 HTML 与接口。
func SetWebCacheDirectory(directory string) error {
	if !filepath.IsAbs(directory) {
		return os.ErrInvalid
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	sharedWebAssets.Lock()
	defer sharedWebAssets.Unlock()
	sharedWebAssets.directory = directory
	return nil
}

func webAssetDirectory(root string, identity [32]byte) string {
	if root == "" {
		return ""
	}
	return filepath.Join(root, hex.EncodeToString(identity[:]))
}

func assetFile(directory, key string) string {
	digest := sha256.Sum256([]byte(key))
	return filepath.Join(directory, hex.EncodeToString(digest[:])+".json")
}

func clearWebAssetFiles(directory string) {
	if directory != "" {
		_ = os.RemoveAll(directory)
	}
}

type diskWebAsset struct {
	Header http.Header
	Body   []byte
	Digest string
}

func readWebAsset(directory, key string) (webAsset, bool) {
	if directory == "" {
		return webAsset{}, false
	}
	path := assetFile(directory, key)
	info, err := os.Stat(path)
	if err != nil || info.Size() > webAssetLimit*2 {
		return webAsset{}, false
	}
	data, err := os.ReadFile(path)
	var entry diskWebAsset
	if err != nil || json.Unmarshal(data, &entry) != nil || len(entry.Body) > webAssetLimit || len(entry.Body) == 0 {
		return webAsset{}, false
	}
	digest := sha256.Sum256(entry.Body)
	if hex.EncodeToString(digest[:]) != entry.Digest {
		return webAsset{}, false
	}
	return webAsset{header: entry.Header, body: entry.Body}, true
}

func writeWebAsset(directory, key string, asset webAsset) {
	if directory == "" {
		return
	}
	if os.MkdirAll(directory, 0700) != nil {
		return
	}
	digest := sha256.Sum256(asset.body)
	data, err := json.Marshal(diskWebAsset{Header: asset.header, Body: asset.body, Digest: hex.EncodeToString(digest[:])})
	if err != nil {
		return
	}
	file, err := os.CreateTemp(directory, ".writing-")
	if err != nil {
		return
	}
	name := file.Name()
	defer os.Remove(name)
	if _, err = file.Write(data); err != nil {
		_ = file.Close()
		return
	}
	if file.Close() != nil || os.Rename(name, assetFile(directory, key)) != nil {
		return
	}
	// 按所有电脑／授权分区一起控制磁盘用量，淘汰较旧的代码版本。
	root := filepath.Dir(directory)
	var files []struct {
		path string
		info os.FileInfo
	}
	var size int64
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() && filepath.Ext(path) == ".json" {
			files = append(files, struct {
				path string
				info os.FileInfo
			}{path, info})
			size += info.Size()
		}
		return nil
	})
	sort.Slice(files, func(i, j int) bool { return files[i].info.ModTime().Before(files[j].info.ModTime()) })
	for _, entry := range files {
		if size <= webAssetDiskBudget {
			break
		}
		if os.Remove(entry.path) == nil {
			size -= entry.info.Size()
		}
	}
}
