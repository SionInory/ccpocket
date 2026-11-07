package netbird

import (
	"context"
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func targetToken(t *testing.T, target string) string {
	t.Helper()
	parsed, err := url.Parse(target)
	if err != nil {
		t.Fatal(err)
	}
	return "/t/" + base64.RawURLEncoding.EncodeToString([]byte(parsed.String()))
}

func localDialer(ctx context.Context, network, address string) (net.Conn, error) {
	return (&net.Dialer{}).DialContext(ctx, network, address)
}

func TestProxyForwardsHTTP(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/hello" || r.URL.RawQuery != "name=cc" {
			t.Errorf("unexpected URL: %s", r.URL.String())
		}
		_, _ = io.WriteString(w, "ok")
	}))
	defer upstream.Close()

	proxy := httptest.NewServer(&proxyHandler{dialContext: localDialer})
	defer proxy.Close()

	response, err := http.Get(proxy.URL + targetToken(t, upstream.URL) + "/hello?name=cc")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if response.StatusCode != http.StatusOK || string(body) != "ok" {
		t.Fatalf("status=%d body=%q", response.StatusCode, body)
	}
}

func TestProxyForwardsWebSocketUpgrade(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			InsecureSkipVerify: true,
		})
		if err != nil {
			return
		}
		defer conn.Close(websocket.StatusNormalClosure, "")
		messageType, payload, err := conn.Read(r.Context())
		if err != nil {
			return
		}
		_ = conn.Write(r.Context(), messageType, payload)
	}))
	defer upstream.Close()

	proxy := httptest.NewServer(&proxyHandler{dialContext: localDialer})
	defer proxy.Close()

	wsURL := "ws://" + strings.TrimPrefix(proxy.URL, "http://") + targetToken(t, upstream.URL) + "/socket"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	if err := conn.Write(ctx, websocket.MessageText, []byte("ping")); err != nil {
		t.Fatal(err)
	}
	_, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != "ping" {
		t.Fatalf("payload=%q", payload)
	}
}

func TestParseTargetPathRejectsUnknownScheme(t *testing.T) {
	token := base64.RawURLEncoding.EncodeToString([]byte("ftp://example.com"))
	if _, _, ok := parseTargetPath("/t/" + token + "/x"); ok {
		t.Fatal("expected invalid target")
	}
}
