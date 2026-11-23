package webgateway

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"sync"
)

// 一个选路代际内，后台离线包和前台代理读取同一份不可变分包。
type webAssetTransfers struct {
	mu        sync.Mutex
	ctx       context.Context
	cancel    context.CancelFunc
	transport *webAssetTransport
	private   webAssetCache
	active    map[string]*webAssetTransfer
}

type webAssetTransfer struct {
	group    *webAssetTransfers
	key      string
	cancel   context.CancelFunc
	ready    chan struct{}
	changed  chan struct{}
	first    *webAssetReader
	readers  map[*webAssetReader]int
	response *http.Response
	raw      bool
	body     bytes.Buffer
	offset   int
	sliding  bool
	err      error
}

type webAssetReader struct {
	transfer *webAssetTransfer
	stop     func() bool
	direct   io.ReadCloser
}

func newWebAssetTransfers(transport *webAssetTransport) *webAssetTransfers {
	ctx, cancel := context.WithCancel(context.Background())
	return &webAssetTransfers{ctx: ctx, cancel: cancel, transport: transport,
		private: webAssetCache{entries: make(map[string]webAsset)}, active: make(map[string]*webAssetTransfer)}
}

func (g *webAssetTransfers) open(req *http.Request, key string) (*http.Response, error) {
	g.mu.Lock()
	d := g.active[key]
	if g.ctx.Err() != nil {
		g.mu.Unlock()
		return nil, g.ctx.Err()
	}
	if d != nil && d.sliding || d == nil && len(g.active) >= webAssetEntryLimit {
		g.mu.Unlock()
		return nil, nil
	}
	r := &webAssetReader{}
	if d == nil {
		if asset, found := g.private.memoryAsset(key); found {
			g.mu.Unlock()
			return asset.response(req), nil
		}
		// 另一个请求可能在本次磁盘读取后刚提交完整缓存。
		if asset, found := g.transport.cache.memoryAsset(key); found {
			g.mu.Unlock()
			return asset.response(req), nil
		}
		ctx, cancel := context.WithCancel(context.WithoutCancel(req.Context()))
		stop := context.AfterFunc(g.ctx, cancel)
		d = &webAssetTransfer{group: g, key: key, cancel: func() { stop(); cancel() },
			first: r, readers: make(map[*webAssetReader]int), ready: make(chan struct{}), changed: make(chan struct{})}
		g.active[key] = d
		go d.run(req.Clone(ctx))
	}
	r.transfer = d
	d.readers[r] = 0
	r.stop = context.AfterFunc(req.Context(), r.release)
	g.mu.Unlock()

	select {
	case <-req.Context().Done():
		r.Close()
		return nil, req.Context().Err()
	case <-d.ready:
	}

	g.mu.Lock()
	if d.raw && d.first != r {
		g.mu.Unlock()
		r.Close()
		return nil, nil
	}
	if d.response == nil {
		err := d.err
		g.mu.Unlock()
		r.Close()
		return nil, err
	}
	res := *d.response
	if d.raw {
		r.direct = res.Body
	}
	g.mu.Unlock()
	res.Header = res.Header.Clone()
	if res.Header == nil {
		res.Header = make(http.Header)
	}
	res.Header.Add("Server-Timing", `weq-remote-source;desc="network"`)
	res.Body, res.Request = r, req
	return &res, nil
}

func (d *webAssetTransfer) removeActive() {
	if d.group.active[d.key] == d {
		delete(d.group.active, d.key)
	}
}

func (d *webAssetTransfer) wake() {
	close(d.changed)
	d.changed = make(chan struct{})
}

func (d *webAssetTransfer) run(req *http.Request) {
	g := d.group
	res, err := g.transport.base.RoundTrip(req)
	g.mu.Lock()
	d.response, d.err = res, err
	if err != nil {
		d.response = nil
		d.removeActive()
		close(d.ready)
		g.mu.Unlock()
		d.cancel()
		return
	}
	share, persist := webAssetPolicy(res)
	d.raw = !share
	close(d.ready)
	if d.raw {
		// 非 immutable 响应可能带 set-cookie 或按请求头变化，仅交给发起者。
		d.removeActive()
		_, owner := d.readers[d.first]
		g.mu.Unlock()
		if !owner {
			res.Body.Close()
		}
		return
	}
	g.mu.Unlock()
	defer d.cancel()
	defer res.Body.Close()
	cache := g.transport.cache
	if !persist {
		cache = &g.private
	}

	buffer := make([]byte, 32<<10)
	for {
		g.mu.Lock()
		for d.sliding && d.body.Len() >= webAssetLimit && req.Context().Err() == nil {
			changed := d.changed
			g.mu.Unlock()
			select {
			case <-changed:
			case <-req.Context().Done():
			}
			g.mu.Lock()
		}
		g.mu.Unlock()
		n, readErr := res.Body.Read(buffer)
		g.mu.Lock()
		if d.body.Len()+n > webAssetLimit {
			d.sliding = true
		}
		_, _ = d.body.Write(buffer[:n])
		d.discardReadBytes()
		if readErr != nil {
			if readErr == io.EOF && !d.sliding && req.Context().Err() == nil &&
				(res.ContentLength < 0 || int64(d.body.Len()) == res.ContentLength) {
				cache.put(d.key, webAsset{header: res.Header.Clone(), body: d.body.Bytes()})
			}
			d.err = readErr
			d.removeActive()
		}
		d.wake()
		g.mu.Unlock()
		if readErr != nil {
			return
		}
	}
}

// 超出代码缓存预算的流仍可交付；滑动窗口只保留现有读者尚未收到的字节。
func (d *webAssetTransfer) discardReadBytes() {
	if !d.sliding {
		return
	}
	through := d.offset + d.body.Len()
	for _, offset := range d.readers {
		through = min(through, offset)
	}
	d.body.Next(through - d.offset)
	d.offset = through
}

func (r *webAssetReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if r.direct != nil {
		return r.direct.Read(p)
	}
	d := r.transfer
	g := d.group
	g.mu.Lock()
	defer g.mu.Unlock()
	for {
		offset, open := d.readers[r]
		if !open {
			return 0, io.ErrClosedPipe
		}
		if offset < d.offset+d.body.Len() {
			n := copy(p, d.body.Bytes()[offset-d.offset:])
			d.readers[r] += n
			if d.sliding {
				d.discardReadBytes()
				d.wake()
			}
			return n, nil
		}
		if d.err != nil {
			return 0, d.err
		}
		changed := d.changed
		g.mu.Unlock()
		<-changed
		g.mu.Lock()
	}
}

func (r *webAssetReader) Close() error {
	r.stop()
	r.release()
	return nil
}

func (r *webAssetReader) release() {
	d := r.transfer
	g := d.group
	g.mu.Lock()
	_, open := d.readers[r]
	if !open {
		g.mu.Unlock()
		return
	}
	delete(d.readers, r)
	d.discardReadBytes()
	d.wake()
	var raw io.ReadCloser
	if d.raw && d.first == r {
		raw = d.response.Body
	}
	if len(d.readers) == 0 {
		d.removeActive()
		d.cancel()
	}
	g.mu.Unlock()
	if raw != nil {
		raw.Close()
	}
}
