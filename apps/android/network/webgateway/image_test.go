package webgateway

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/synctest"
	"time"
)

func TestLocalImageRequiresCookieAndIsConsumedOnce(t *testing.T) {
	secret := strings.Repeat("a", 64)
	gateway, err := Open(strings.Repeat("b", 64), secret)
	if err != nil {
		t.Fatal(err)
	}
	defer gateway.Close()
	id := strings.Repeat("c", 32)
	input := bytes.Repeat([]byte{0, 17, 200, 255}, MaxImageBytes/4)
	expected := bytes.Clone(input)
	if !gateway.StoreImage(id, "image/png", input) {
		t.Fatal("could not hand off bounded image")
	}
	input[0] = 123

	get := func(cookie, origin, method string) (int, http.Header, []byte) {
		t.Helper()
		req, err := http.NewRequestWithContext(t.Context(), method, gateway.Origin()+imagePath+id, nil)
		if err != nil {
			t.Fatal(err)
		}
		if cookie != "" {
			req.AddCookie(&http.Cookie{Name: "weq_remote_local", Value: cookie})
		}
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, err := io.ReadAll(res.Body)
		if err != nil {
			t.Fatal(err)
		}
		return res.StatusCode, res.Header, body
	}
	if status, _, _ := get("", "", http.MethodGet); status != http.StatusForbidden {
		t.Fatalf("unauthenticated image read: HTTP %d", status)
	}
	if status, _, _ := get(secret, "http://other.invalid", http.MethodGet); status != http.StatusForbidden {
		t.Fatalf("cross-origin image read: HTTP %d", status)
	}
	if status, _, _ := get(secret, gateway.Origin(), http.MethodHead); status != http.StatusMethodNotAllowed {
		t.Fatalf("non-consuming image request: HTTP %d", status)
	}
	status, headers, body := get(secret, gateway.Origin(), http.MethodGet)
	if status != http.StatusOK || headers.Get("Content-Type") != "image/png" || headers.Get("Cache-Control") != "no-store" || !bytes.Equal(body, expected) {
		t.Fatalf("incorrect binary image: HTTP %d, %d bytes, %v", status, len(body), headers)
	}
	if status, _, _ := get(secret, gateway.Origin(), http.MethodGet); status != http.StatusNotFound {
		t.Fatalf("image can be read more than once: HTTP %d", status)
	}
}

func TestUnreadLocalImagesExpireAndAreBounded(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		gateway := &Gateway{}
		for _, digit := range []string{"1", "2", "3", "4"} {
			if !gateway.StoreImage(strings.Repeat(digit, 32), "image/png", []byte{1}) {
				t.Fatalf("image %s could not be stored", digit)
			}
		}
		id := strings.Repeat("5", 32)
		if gateway.StoreImage(id, "image/png", []byte{1}) {
			t.Fatal("accepts too many unread images")
		}
		writer := &blockingImageWriter{ResponseRecorder: httptest.NewRecorder(), resume: make(chan struct{})}
		go gateway.serveImage(writer, httptest.NewRequest(http.MethodGet, "/", nil), strings.Repeat("4", 32))
		synctest.Wait()
		if gateway.StoreImage(id, "image/png", []byte{1}) {
			t.Fatal("does not count the response still being delivered")
		}
		close(writer.resume)
		time.Sleep(localImageLifetime)
		synctest.Wait()
		rec := httptest.NewRecorder()
		gateway.serveImage(rec, httptest.NewRequest(http.MethodGet, "/", nil), strings.Repeat("1", 32))
		if rec.Code != http.StatusNotFound {
			t.Fatal("expired image can still be read")
		}
		if gateway.StoreImage(id, "text/html", []byte{1}) || gateway.StoreImage(id, "image/png", make([]byte, MaxImageBytes+1)) {
			t.Fatal("accepts invalid image content")
		}
		if !gateway.StoreImage(id, "image/png", []byte{1}) {
			t.Fatal("expired slot was not released")
		}
	})
}

type blockingImageWriter struct {
	*httptest.ResponseRecorder
	resume chan struct{}
}

func (w *blockingImageWriter) Write(body []byte) (int, error) {
	<-w.resume
	return w.ResponseRecorder.Write(body)
}
