package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/tailscale/libtailscale/webgateway"
)

var weqGateways struct {
	sync.Mutex
	next   C.int
	active map[C.int]*webgateway.Gateway
}

func weqGateway(id C.int) *webgateway.Gateway {
	weqGateways.Lock()
	defer weqGateways.Unlock()
	return weqGateways.active[id]
}

//export WeQOpenGateway
func WeQOpenGateway(token, secret, cache, storage *C.char) C.int {
	if webgateway.SetWebCacheDirectory(C.GoString(cache)) != nil ||
		webgateway.SetWebStorageDirectory(C.GoString(storage)) != nil {
		return 0
	}
	gateway, err := webgateway.Open(C.GoString(token), C.GoString(secret))
	if err != nil {
		return 0
	}
	weqGateways.Lock()
	defer weqGateways.Unlock()
	if weqGateways.active == nil {
		weqGateways.active = make(map[C.int]*webgateway.Gateway)
	}
	weqGateways.next++
	weqGateways.active[weqGateways.next] = gateway
	return weqGateways.next
}

//export WeQGatewayOrigin
func WeQGatewayOrigin(id C.int) *C.char {
	if gateway := weqGateway(id); gateway != nil {
		return C.CString(gateway.Origin())
	}
	return nil
}

//export WeQGatewayHasRelease
func WeQGatewayHasRelease(id C.int) C.int {
	if gateway := weqGateway(id); gateway != nil && gateway.HasRelease() {
		return 1
	}
	return 0
}

//export WeQAttachGateway
func WeQAttachGateway(id, node C.int, endpoint, fingerprint *C.char) C.int {
	gateway := weqGateway(id)
	target, err := url.Parse(C.GoString(endpoint))
	if gateway == nil || err != nil || target.Host == "" {
		return 0
	}
	transport := &http.Transport{MaxIdleConns: 32, MaxIdleConnsPerHost: 8,
		IdleConnTimeout: 90 * time.Second, ResponseHeaderTimeout: 12 * time.Second}
	switch {
	case target.Scheme == "http" && node > 0:
		server := getServer(node)
		if server == nil {
			return 0
		}
		transport.DialContext = server.s.Dial
	case target.Scheme == "https" && webgateway.Credential(C.GoString(fingerprint)):
		pin := C.GoString(fingerprint)
		transport.ForceAttemptHTTP2 = true
		transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true,
			VerifyConnection: func(state tls.ConnectionState) error {
				if len(state.PeerCertificates) == 0 {
					return errors.New("certificate unavailable")
				}
				digest := sha256.Sum256(state.PeerCertificates[0].Raw)
				if hex.EncodeToString(digest[:]) != pin {
					return errors.New("computer certificate changed; pair again")
				}
				return nil
			}}
	default:
		return 0
	}
	gateway.Attach(target, transport)
	return 1
}

//export WeQCloseGateway
func WeQCloseGateway(id C.int) {
	weqGateways.Lock()
	gateway := weqGateways.active[id]
	delete(weqGateways.active, id)
	weqGateways.Unlock()
	if gateway != nil {
		gateway.Close()
	}
}

//export WeQClearGatewayCache
func WeQClearGatewayCache(cache *C.char) {
	if webgateway.SetWebCacheDirectory(C.GoString(cache)) == nil {
		webgateway.ClearWebCache()
	}
}
