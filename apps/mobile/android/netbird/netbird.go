// Package netbird embeds the Netbird userspace client for the Android app.
package netbird

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	nbembed "github.com/netbirdio/netbird/client/embed"
)

const (
	stateIdle       = "idle"
	stateConnecting = "connecting"
	stateConnected  = "connected"
	stateError      = "error"

	targetPathPrefix = "/t/"
)

// Client owns one process-wide Netbird tunnel and a loopback reverse proxy.
type Client struct {
	mu          sync.Mutex
	client      *nbembed.Client
	proxy       *http.Server
	proxyPort   int
	state       string
	lastError   string
	configDir   string
	stopChannel chan struct{}
}

// NewClient creates an idle Netbird client.
func NewClient() *Client {
	return &Client{state: stateIdle}
}

// Start connects to Netbird and starts the loopback reverse proxy.
func (c *Client) Start(
	managementURL string,
	setupKey string,
	deviceName string,
	configDir string,
) error {
	managementURL = strings.TrimSpace(managementURL)
	setupKey = strings.TrimSpace(setupKey)
	deviceName = strings.TrimSpace(deviceName)
	configDir = strings.TrimSpace(configDir)

	c.mu.Lock()
	if c.client != nil {
		c.mu.Unlock()
		return errors.New("Netbird 已在运行")
	}
	c.state = stateConnecting
	c.lastError = ""
	c.configDir = configDir
	c.mu.Unlock()

	if managementURL == "" {
		return c.fail("Management URL 不能为空")
	}
	if setupKey == "" {
		return c.fail("Setup Key 不能为空")
	}
	if deviceName == "" {
		return c.fail("设备名不能为空")
	}
	if configDir == "" {
		return c.fail("配置目录不能为空")
	}
	parsedManagementURL, err := url.Parse(managementURL)
	if err != nil || parsedManagementURL.Scheme == "" || parsedManagementURL.Host == "" {
		return c.fail(fmt.Sprintf("Management URL 无效：%s", managementURL))
	}
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		return c.fail(fmt.Sprintf("创建配置目录失败：%v", err))
	}

	configPath := filepath.Join(configDir, "config.json")
	statePath := filepath.Join(configDir, "state.json")
	client, err := nbembed.New(nbembed.Options{
		DeviceName:    deviceName,
		SetupKey:      setupKey,
		ManagementURL: managementURL,
		ConfigPath:    configPath,
		StatePath:     statePath,
		LogOutput:     os.Stderr,
		LogLevel:      "info",
	})
	if err != nil {
		return c.fail(fmt.Sprintf("创建 Netbird 客户端失败：%v", err))
	}

	startCtx, cancelStart := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancelStart()
	if err := client.Start(startCtx); err != nil {
		stopNetbird(client)
		return c.fail(fmt.Sprintf("连接 Netbird 失败：%v", err))
	}

	if err := waitForTunnel(client, 30*time.Second); err != nil {
		stopNetbird(client)
		return c.fail(err.Error())
	}

	port, err := c.startProxy(client)
	if err != nil {
		stopNetbird(client)
		return c.fail(fmt.Sprintf("启动本地代理失败：%v", err))
	}

	stopChannel := make(chan struct{})
	c.mu.Lock()
	c.client = client
	c.proxyPort = port
	c.state = stateConnected
	c.lastError = ""
	c.stopChannel = stopChannel
	c.mu.Unlock()

	go c.watch(stopChannel)
	return nil
}

func waitForTunnel(client *nbembed.Client, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		status, err := client.Status()
		if err == nil {
			if status.ManagementState.Connected && status.SignalState.Connected {
				return nil
			}
			if status.ManagementState.Error != nil {
				lastErr = status.ManagementState.Error
			}
			if status.SignalState.Error != nil {
				lastErr = status.SignalState.Error
			}
		} else {
			lastErr = err
		}
		time.Sleep(250 * time.Millisecond)
	}
	if lastErr != nil {
		return fmt.Errorf("Netbird 隧道连接超时：%v", lastErr)
	}
	return errors.New("Netbird 隧道连接超时")
}

func stopNetbird(client *nbembed.Client) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = client.Stop(ctx)
}

func (c *Client) watch(stop <-chan struct{}) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			c.mu.Lock()
			client := c.client
			c.mu.Unlock()
			if client == nil {
				return
			}
			status, err := client.Status()
			if err != nil {
				c.setError(fmt.Sprintf("读取 Netbird 状态失败：%v", err))
				continue
			}
			switch {
			case status.ManagementState.Connected && status.SignalState.Connected:
				c.mu.Lock()
				if c.client == client {
					c.state = stateConnected
					c.lastError = ""
				}
				c.mu.Unlock()
			case status.ManagementState.Error != nil:
				c.setError(fmt.Sprintf("Netbird 管理连接失败：%v", status.ManagementState.Error))
			case status.SignalState.Error != nil:
				c.setError(fmt.Sprintf("Netbird 信号连接失败：%v", status.SignalState.Error))
			default:
				c.mu.Lock()
				if c.client == client {
					c.state = stateConnecting
					c.lastError = ""
				}
				c.mu.Unlock()
			}
		}
	}
}

func (c *Client) setError(message string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.client == nil {
		return
	}
	c.state = stateError
	c.lastError = message
}

func (c *Client) fail(message string) error {
	c.mu.Lock()
	c.state = stateError
	c.lastError = message
	c.mu.Unlock()
	return errors.New(message)
}

// Stop closes the proxy and stops Netbird.
func (c *Client) Stop() error {
	c.mu.Lock()
	client := c.client
	proxy := c.proxy
	stopChannel := c.stopChannel
	c.client = nil
	c.proxy = nil
	c.proxyPort = 0
	c.state = stateIdle
	c.lastError = ""
	c.stopChannel = nil
	c.mu.Unlock()

	if stopChannel != nil {
		close(stopChannel)
	}
	var firstErr error
	if proxy != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		if err := proxy.Shutdown(ctx); err != nil {
			firstErr = err
		}
		cancel()
	}
	if client != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		if err := client.Stop(ctx); err != nil && !errors.Is(err, nbembed.ErrClientNotStarted) && firstErr == nil {
			firstErr = err
		}
		cancel()
	}
	return firstErr
}

// ClearLogin stops the tunnel and removes the persisted Netbird config/state.
func (c *Client) ClearLogin() error {
	stopErr := c.Stop()
	c.mu.Lock()
	dir := c.configDir
	c.mu.Unlock()
	if dir == "" {
		return stopErr
	}
	clearErr := os.RemoveAll(dir)
	if clearErr == nil {
		clearErr = os.MkdirAll(dir, 0o700)
	}
	return errors.Join(stopErr, clearErr)
}

// Status returns a JSON snapshot for Dart.
func (c *Client) Status() string {
	c.mu.Lock()
	state := c.state
	lastError := c.lastError
	port := c.proxyPort
	client := c.client
	c.mu.Unlock()

	managementConnected := false
	signalConnected := false
	peerCount := 0
	connectedPeers := 0
	if client != nil {
		if status, err := client.Status(); err == nil {
			managementConnected = status.ManagementState.Connected
			signalConnected = status.SignalState.Connected
			peerCount = len(status.Peers)
			for _, peer := range status.Peers {
				if peer.ConnStatus == nbembed.PeerStatusConnected {
					connectedPeers++
				}
			}
		}
	}
	payload := map[string]any{
		"state":               state,
		"error":               lastError,
		"proxyPort":           port,
		"managementConnected": managementConnected,
		"signalConnected":     signalConnected,
		"peerCount":           peerCount,
		"connectedPeers":      connectedPeers,
	}
	encoded, _ := json.Marshal(payload)
	return string(encoded)
}

// ProxyPort returns the loopback proxy port, or 0 when stopped.
func (c *Client) ProxyPort() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.proxyPort
}

func (c *Client) startProxy(client *nbembed.Client) (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	handler := &proxyHandler{dialContext: client.DialContext}
	server := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 15 * time.Second,
	}
	c.mu.Lock()
	c.proxy = server
	c.mu.Unlock()
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("Netbird proxy stopped: %v", err)
		}
	}()
	return port, nil
}

type dialContextFunc func(context.Context, string, string) (net.Conn, error)

type proxyHandler struct {
	dialContext dialContextFunc
}

// ServeHTTP routes /t/<base64url-target>/<path> to the encoded target through
// Netbird. The same path form carries WebSocket upgrades.
func (h *proxyHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	target, remainingPath, ok := parseTargetPath(r.URL.EscapedPath())
	if !ok {
		http.Error(w, "Netbird 代理目标无效", http.StatusBadRequest)
		return
	}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme = target.Scheme
			pr.Out.URL.Host = target.Host
			pr.Out.URL.Path = remainingPath
			pr.Out.URL.RawPath = ""
			pr.Out.Host = target.Host
			pr.SetXForwarded()
		},
		Transport: &http.Transport{
			DialContext:           h.dialContext,
			ForceAttemptHTTP2:     false,
			MaxIdleConns:          32,
			IdleConnTimeout:       60 * time.Second,
			TLSHandshakeTimeout:   15 * time.Second,
			ExpectContinueTimeout: time.Second,
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("Netbird proxy request failed: %v", err)
			http.Error(w, "Netbird 请求失败", http.StatusBadGateway)
		},
	}
	proxy.ServeHTTP(w, r)
}

func parseTargetPath(escapedPath string) (*url.URL, string, bool) {
	if !strings.HasPrefix(escapedPath, targetPathPrefix) {
		return nil, "", false
	}
	rest := strings.TrimPrefix(escapedPath, targetPathPrefix)
	token, remaining, found := strings.Cut(rest, "/")
	if !found {
		remaining = ""
	}
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return nil, "", false
	}
	target, err := url.Parse(string(decoded))
	if err != nil || target.Scheme == "" || target.Host == "" {
		return nil, "", false
	}
	if target.Scheme != "http" && target.Scheme != "https" {
		return nil, "", false
	}
	path, err := url.PathUnescape(remaining)
	if err != nil {
		return nil, "", false
	}
	if path == "" {
		path = "/"
	} else if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	return target, path, true
}
