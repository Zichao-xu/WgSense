// Package proxy 封装 Mihomo/Clash RESTful API 客户端，提供代理管理的完整能力。
// 支持：策略组/节点管理、延迟测试、连接控制、实时数据流(WebSocket)、规则查看、配置修改。
package proxy

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"bufio"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"go.uber.org/zap"
)

// DefaultMihomoPort Mihomo API 默认端口
const DefaultMihomoPort = 9090

// DefaultLatencyTestURL 默认延迟测试地址
const DefaultLatencyTestURL = "http://www.gstatic.com/generate_204"

// Config Mihomo 连接配置
type Config struct {
	Address string // 如 "10.10.1.1:9090" 或 "127.0.0.1:9090"
	Secret  string // API 密钥（可为空）

	LatencyTestURL  string // 延迟测试 URL
	LatencyTimeout  int    // 延迟超时（毫秒），默认 5000
	LatencyLow      int    // 低延迟阈值（毫秒），默认 200
	LatencyMedium   int    // 中延迟阈值（毫秒），默认 500
}

// DefaultConfig 返回远程软路由的默认配置
func DefaultConfig() *Config {
	return &Config{
		Address:         "10.10.1.1:9090",
		Secret:          "",
		LatencyTestURL:  DefaultLatencyTestURL,
		LatencyTimeout:  5000,
		LatencyLow:      200,
		LatencyMedium:   500,
	}
}

// Client 是 Mihomo API 客户端
type Client struct {
	cfg    *Config
	http   *http.Client
	logger *zap.SugaredLogger

	mu       sync.RWMutex
	baseURL  string // "http://host:port"
	version  string // 缓存的版本信息
}

// NewClient 创建 Mihomo API 客户端
func NewClient(cfg *Config) (*Client, error) {
	if cfg == nil {
		cfg = DefaultConfig()
	}
	if cfg.LatencyTestURL == "" {
		cfg.LatencyTestURL = DefaultLatencyTestURL
	}
	if cfg.LatencyTimeout <= 0 {
		cfg.LatencyTimeout = 5000
	}

	logger, _ := zap.NewProduction()
	baseURL := fmt.Sprintf("http://%s", strings.TrimPrefix(cfg.Address, "http://"))

	c := &Client{
		cfg:    cfg,
		http:   &http.Client{Timeout: 15 * time.Second},
		logger: logger.Sugar(),
		baseURL: baseURL,
	}
	return c, nil
}

// doRequest 执行带认证的 HTTP 请求
func (c *Client) doRequest(method, path string, body interface{}) ([]byte, int, error) {
	var bodyReader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, 0, fmt.Errorf("序列化请求体失败: %w", err)
		}
		bodyReader = bytes.NewReader(data)
	}

	reqURL := c.baseURL + path
	req, err := http.NewRequest(method, reqURL, bodyReader)
	if err != nil {
		return nil, 0, fmt.Errorf("创建请求失败: %w", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.cfg.Secret != "" {
		req.Header.Set("Authorization", "Bearer "+c.cfg.Secret)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, 0, fmt.Errorf("请求失败 %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	respData, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, resp.StatusCode, fmt.Errorf("读取响应失败: %w", err)
	}
	return respData, resp.StatusCode, nil
}

// get 简化 GET 请求
func (c *Client) get(path string) ([]byte, error) {
	data, code, err := c.doRequest("GET", path, nil)
	if err != nil {
		return data, err
	}
	if code >= 400 {
		return data, fmt.Errorf("API 错误 %d: %s", code, string(data))
	}
	return data, nil
}

// put 简化 PUT 请求
func (c *Client) put(path string, body interface{}) ([]byte, error) {
	data, code, err := c.doRequest("PUT", path, body)
	if err != nil {
		return data, err
	}
	if code >= 400 {
		return data, fmt.Errorf("API 错误 %d: %s", code, string(data))
	}
	return data, nil
}

// patch 简化 PATCH 请求
func (c *Client) patch(path string, body interface{}) ([]byte, error) {
	data, code, err := c.doRequest("PATCH", path, body)
	if err != nil {
		return data, err
	}
	if code >= 400 {
		return data, fmt.Errorf("API 错误 %d: %s", code, string(data))
	}
	return data, nil
}

// del 简化 DELETE 请求
func (c *Client) del(path string) (int, error) {
	_, code, err := c.doRequest("DELETE", path, nil)
	if err != nil {
		return 0, err
	}
	if code >= 400 {
		return code, fmt.Errorf("API 错误 %d", code)
	}
	return code, nil
}

// ==================== 版本信息 ====================

// VersionResponse Mihomo 版本响应
type VersionResponse struct {
	Meta     bool   `json:"meta"`
	Version  string `json:"version"`
	Premium  bool   `json:"premium"`
	Foundation bool `json:"foundation"`
}

// GetVersion 获取 Mihomo 核心版本
func (c *Client) GetVersion() (*VersionResponse, error) {
	data, err := c.get("/version")
	if err != nil {
		return nil, err
	}
	var v VersionResponse
	if err := json.Unmarshal(data, &v); err != nil {
		return nil, fmt.Errorf("解析版本信息失败: %w", err)
	}
	c.mu.Lock()
	c.version = v.Version
	c.mu.Unlock()
	return &v, nil
}

// ==================== 代理/策略组 ====================

// ProxiesResponse 代理列表响应
type ProxiesResponse struct {
	Proxies map[string]ProxyInfo `json:"proxies"`
}

// ProxyInfo 单个代理（节点或策略组）
type ProxyInfo struct {
	Name     string            `json:"name"`
	Type     string            `json:"type"` // Selector/Fallback/URLTest/LoadBalance/Smart/PassThrough/Reject/Compatible/Unknown
	All      []string          `json:"all"`   // 可选节点列表
	Now      string            `json:"now"`   // 当前选中节点
	History  []DelayHistory    `json:"history"` // 延迟历史
	Alive    bool              `json:"alive"`
	Uptime   uint64            `json:"uptime"`
	Provider string            `json:"provider"`

	// 节点详情（叶子节点才有）
	UDP  bool `json:"udp"`
	XUDP bool `json:"xudp"`

	// Smart 类型
	NowTagID string `json:"now-tag-id"`
}

// DelayHistory 延迟历史记录
type DelayHistory struct {
	Time  time.Time `json:"time"`
	Delay int64     `json:"delay"`
}

// GetProxies 获取所有代理（策略组 + 节点）
func (c *Client) GetProxies() (*ProxiesResponse, error) {
	data, err := c.get("/proxies")
	if err != nil {
		return nil, err
	}
	var r ProxiesResponse
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("解析代理列表失败: %w", err)
	}
	return &r, nil
}

// SelectProxy 切换策略组的选中节点
func (c *Client) SelectProxy(groupName, proxyName string) error {
	body := map[string]string{"name": proxyName}
	_, err := c.put(fmt.Sprintf("/proxies/%s", url.PathEscape(groupName)), body)
	return err
}

// DeleteFixedSelection 清除 URLTest 组的固定选择
func (c *Client) DeleteFixedSelection(groupName string) error {
	_, err := c.del(fmt.Sprintf("/proxies/%s", url.PathEscape(groupName)))
	return err
}

// DelayResponse 延迟测试响应
type DelayResponse struct {
	Delay   int64  `json:"delay"`
	Message string `json:"message,omitempty"`
	Error   string `json:"error,omitempty"`
}

// TestProxyDelay 测试单个节点延迟
func (c *Client) TestProxyDelay(proxyName string) (*DelayResponse, error) {
	testURL := c.cfg.LatencyTestURL
	timeout := c.cfg.LatencyTimeout
	path := fmt.Sprintf("/proxies/%s/delay?url=%s&timeout=%d",
		url.PathEscape(proxyName), url.QueryEscape(testURL), timeout)
	data, _, err := c.doRequest("GET", path, nil)
	if err != nil {
		return nil, err
	}
	var r DelayResponse
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("解析延迟结果失败: %w", err)
	}
	return &r, nil
}

// TestGroupDelay 测试整个策略组所有节点的延迟
func (c *Client) TestGroupDelay(groupName string) (*DelayResponse, error) {
	testURL := c.cfg.LatencyTestURL
	timeout := c.cfg.LatencyTimeout
	path := fmt.Sprintf("/group/%s/delay?url=%s&timeout=%d",
		url.PathEscape(groupName), url.QueryEscape(testURL), timeout)
	data, _, err := c.doRequest("GET", path, nil)
	if err != nil {
		return nil, err
	}
	var r DelayResponse
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("解析组延迟结果失败: %w", err)
	}
	return &r, nil
}

// ==================== Provider ====================

// ProxyProvidersResponse 代理 Provider 列表
type ProxyProvidersResponse struct {
	Providers map[string]ProxyProviderInfo `json:"providers"`
}

// ProxyProviderInfo 代理 Provider 信息
type ProxyProviderInfo struct {
	Name             string    `json:"name"`
	Type             string    `json:"type"`
	VehicleType      string    `json:"vehicleType"`
	UpdatedAt        time.Time `json:"updatedAt"`
	ProxyCount       int       `json:"proxyCount"`
	SubscriptionInfo string    `json:"subscriptionInfo,omitempty"`
}

// GetProxyProviders 获取所有代理 Provider
func (c *Client) GetProxyProviders() (*ProxyProvidersResponse, error) {
	data, err := c.get("/providers/proxies")
	if err != nil {
		return nil, err
	}
	var r ProxyProvidersResponse
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("解析 Provider 失败: %w", err)
	}
	return &r, nil
}

// UpdateProxyProvider 更新代理订阅
func (c *Client) UpdateProxyProvider(name string) error {
	_, err := c.put(fmt.Sprintf("/providers/proxies/%s", url.PathEscape(name)), nil)
	return err
}

// HealthCheckProvider 对 Provider 进行健康检查
func (c *Client) HealthCheckProvider(name string) error {
	_, _, err := c.doRequest("GET",
		fmt.Sprintf("/providers/proxies/%s/healthcheck?timeout=15000", url.PathEscape(name)), nil)
	return err
}

// ==================== 规则 ====================

// RulesResponse 规则列表响应
type RulesResponse struct {
	Rules []RuleInfo `json:"rules"`
}

// RuleInfo 规则条目
type RuleInfo struct {
	Type     string   `json:"type"`
	Payload  string   `json:"payload"`
	Proxy    string   `json:"proxy"`
	Chains   []string `json:"chains"`
	Size     int64    `json:"size"`
}

// GetRules 获取当前生效的规则链
func (c *Client) GetRules() (*RulesResponse, error) {
	data, err := c.get("/rules")
	if err != nil {
		return nil, err
	}
	var r RulesResponse
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("解析规则失败: %w", err)
	}
	return &r, nil
}

// ToggleRuleDisabled 启用/禁用规则（仅 Clash 核心）
func (c *Client) ToggleRuleDisabled(payload string, disabled bool) error {
	body := map[string]interface{}{"payload": payload, "disabled": disabled}
	_, err := c.patch("/rules/disable", body)
	return err
}

// RuleProvidersResponse 规则 Provider 列表
type RuleProvidersResponse struct {
	Providers map[string]RuleProviderInfo `json:"providers"`
}

// RuleProviderInfo 规则 Provider 信息
type RuleProviderInfo struct {
	Name      string    `json:"name"`
	Type      string    `json:"type"`
	Behavior  string    `json:"behavior"`
	RuleCount int       `json:"ruleCount"`
	UpdatedAt time.Time `json:"updatedAt"`
}

// GetRuleProviders 获取规则 Provider
func (c *Client) GetRuleProviders() (*RuleProvidersResponse, error) {
	data, err := c.get("/providers/rules")
	if err != nil {
		return nil, err
	}
	var r RuleProvidersResponse
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("解析规则 Provider 失败: %w", err)
	}
	return &r, nil
}

// UpdateRuleProvider 更新规则 Provider
func (c *Client) UpdateRuleProvider(name string) error {
	_, err := c.put(fmt.Sprintf("/providers/rules/%s", url.PathEscape(name)), nil)
	return err
}

// ==================== 配置 ====================

// ConfigsResponse 运行配置响应
type ConfigsResponse struct {
	Mode           string `json:"mode"`            // global/direct/rule
	LogLevel       string `json:"log-level"`
	AllowLan       bool   `json:"allow-lan"`
	ExternalController string `json:"external-controller"`
	Secret         string `json:"secret"`
	TunEnable      bool   `json:"tun-enable"`
	MixedPort      int    `json:"mixed-port"`
	RedirPort      int    `json:"redir-port"`
	SocksPort      int    `json:"socks-port"`
	Port           int    `json:"port"`
	ExternalUI     string `json:"external-ui"`
	ExternalUIDownloadURL string `json:"external-ui-url"`
}

// GetConfigs 获取运行配置
func (c *Client) GetConfigs() (*ConfigsResponse, error) {
	data, err := c.get("/configs")
	if err != nil {
		return nil, err
	}
	var r ConfigsResponse
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("解析运行配置失败: %w", err)
	}
	return &r, nil
}

// PatchConfigs 修改运行时配置
func (c *Client) PatchConfigs(patch map[string]interface{}) error {
	_, err := c.patch("/configs", patch)
	return err
}

// SetMode 设置运行模式
func (c *Client) SetMode(mode string) error { // global / direct / rule
	return c.PatchConfigs(map[string]interface{}{"mode": mode})
}

// SetTUN 切换 TUN 模式
func (c *Client) SetTUN(enable bool) error {
	return c.PatchConfigs(map[string]interface{}{"tun-enable": enable})
}

// FlushFakeIP 清空 FakeIP 缓存
func (c *Client) FlushFakeIP() error {
	_, _, err := c.doRequest("POST", "/cache/fakeip/flush", nil)
	return err
}

// FlushDNSCache 清空 DNS 缓存
func (c *Client) FlushDNSCache() error {
	_, _, err := c.doRequest("POST", "/cache/dns/flush", nil)
	return err
}

// ReloadConfigs 重载配置文件
func (c *Client) ReloadConfigs() error {
	_, err := c.put("/configs?reload=true", nil)
	return err
}

// DNSQuery DNS 查询
func (c *Client) DNSQuery(name string, qtype string) ([]byte, error) {
	path := fmt.Sprintf("/dns/query?name=%s&type=%s", url.QueryEscape(name), qtype)
	data, err := c.get(path)
	return data, err
}

// RestartCore 重启核心
func (c *Client) RestartCore() error {
	_, _, err := c.doRequest("POST", "/restart", nil)
	return err
}

// UpgradeCore 升级核心
func (c *Client) UpgradeCore(channel string) error {
	path := "/upgrade"
	if channel != "" {
		path += "?channel=" + channel
	}
	_, _, err := c.doRequest("POST", path, nil)
	return err
}

// UpdateGeoData 更新 GeoIP/GeoSite 数据库
func (c *Client) UpdateGeoData() error {
	_, _, err := c.doRequest("POST", "/configs/geo", nil)
	return err
}

// ==================== 连接管理 ====================// ConnectionsResponse 活跃连接列表响应
type ConnectionsResponse struct {
	DownloadTotal int64               `json:"downloadTotal"`
	UploadTotal   int64               `json:"uploadTotal"`
	Connections   []ConnectionDetail  `json:"connections"`
}

// ConnectionDetail 单个连接详情
type ConnectionDetail struct {
	ID           string            `json:"id"`
	Metadata     ConnectionMetadata `json:"metadata"`
	Upload       int64             `json:"upload"`
	Download     int64             `json:"download"`
	Start        time.Time         `json:"start"`
	Chains       []string          `json:"chains"`
	Rule         string            `json:"rule"`
	RulePayload  string            `json:"rulePayload"`
	UploadSpeed  int64             `json:"uploadSpeed"`
	DownloadSpeed int64            `json:"downloadSpeed"`
	Alive        bool              `json:"alive"`
}

// ConnectionMetadata 连接元数据
type ConnectionMetadata struct {
	NetWork      string `json:"network"`
	Type         string `json:"type"`
	SourceIP     string `json:"sourceIP"`
	SourcePort   string `json:"sourcePort"`
	DestIP       string `json:"destinationIP"`
	DestPort     string `json:"destinationPort"`
	Host         string `json:"host"`
	DNSMode      string `json:"dnsMode"`
	Process      string `json:"process"`
	ProcessPath  string `json:"processPath"`
	RemoteDest   string `json:"remoteDestination"`
	TCPFlags     string `json:"tcpFlags"`
	InboundIP    string `json:"inboundIp"`
	InboundPort  string `json:"inboundPort"`
	SpecialProxy string `json:"specialRules"`
}

// GetConnections 获取活跃连接快照
func (c *Client) GetConnections() (*ConnectionsResponse, error) {
	data, err := c.get("/connections")
	if err != nil {
		return nil, err
	}
	var r ConnectionsResponse
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("解析连接列表失败: %w", err)
	}
	return &r, nil
}

// CloseConnection 关闭指定连接
func (c *Client) CloseConnection(id string) error {
	_, err := c.del(fmt.Sprintf("/connections/%s", id))
	return err
}

// CloseAllConnections 关闭全部连接
func (c *Client) CloseAllConnections() error {
	_, err := c.del("/connections")
	return err
}

// BlockConnection 阻断智能连接（Smart 规则）
func (c *Client) BlockConnection(id string) error {
	_, err := c.del(fmt.Sprintf("/connections/smart/%s", id))
	return err
}

// ==================== WebSocket ====================

// WSMessage WebSocket 消息类型
type WSMessage struct {
	Data  json.RawMessage
	Error error
}

// SubscribeConnections 订阅实时连接流（WebSocket）
// 返回消息通道和取消函数。ctx 取消或调用 cancel 会关闭连接。
func (c *Client) SubscribeConnections(ctx context.Context) (<-chan WSMessage, context.CancelFunc, error) {
	wsURL := strings.Replace(c.baseURL, "http://", "ws://", 1) + "/connections"
	return c.subscribeWS(ctx, wsURL)
}

// SubscribeTraffic 订阅实时流量统计（WebSocket）
func (c *Client) SubscribeTraffic(ctx context.Context) (<-chan WSMessage, context.CancelFunc, error) {
	wsURL := strings.Replace(c.baseURL, "http://", "ws://", 1) + "/traffic"
	return c.subscribeWS(ctx, wsURL)
}

// SubscribeLogs 订阅实时日志（WebSocket）
func (c *Client) SubscribeLogs(ctx context.Context, logLevel string) (<-chan WSMessage, context.CancelFunc, error) {
	wsURL := strings.Replace(c.baseURL, "http://", "ws://", 1) + "/logs"
	if logLevel != "" {
		wsURL += "?level=" + logLevel
	}
	return c.subscribeWS(ctx, wsURL)
}

// subscribeWS 通用 WebSocket 订阅
func (c *Client) subscribeWS(ctx context.Context, wsURL string) (<-chan WSMessage, context.CancelFunc, error) {
	ctx2, cancel := context.WithCancel(ctx)

	ch := make(chan WSMessage, 64)
	go func() {
		defer close(ch)
		defer cancel()
		for {
			select {
			case <-ctx2.Done():
				return
			default:
			}

			conn, resp, err := defaultDialer.DialContext(ctx2, wsURL, nil)
			if err != nil {
				if resp != nil {
					c.logger.Warnf("WS 连接失败(%s): %s", wsURL, resp.Status)
				} else {
					c.logger.Warnf("WS 连接失败(%s): %v", wsURL, err)
				}
				select {
				case <-ctx2.Done():
					return
				case <-time.After(3 * time.Second):
					continue
				}
			}

			// 读取循环
			buf := make([]byte, 65536)
			for {
				select {
				case <-ctx2.Done():
					conn.Close()
					return
				default:
				}

				conn.SetReadDeadline(time.Now().Add(60 * time.Second))
				n, err := conn.ReadMessage(buf)
				if err != nil {
					conn.Close()
					c.logger.Debugf("WS 断开(%s): %v", wsURL, err)
					// 重连
					select {
					case <-ctx2.Done():
						return
					case <-time.After(3 * time.Second):
						break // 外层重连循环
					}
				}

				msg := make([]byte, n)
				copy(msg, buf[:n])
				select {
				case ch <- WSMessage{Data: msg}:
				case <-ctx2.Done():
					conn.Close()
					return
				}
			}
		}
	}()

	return ch, cancel, nil
}

// Ping 测试连通性（轻量级健康检查）
func (c *Client) Ping() error {
	_, err := c.get("/version")
	return err
}

// SetAddress 动态切换目标地址
func (c *Client) SetAddress(addr string) {
	c.mu.Lock()
	c.baseURL = fmt.Sprintf("http://%s", strings.TrimPrefix(addr, "http://"))
	c.cfg.Address = addr
	c.mu.Unlock()
}

// GetBaseURL 获取当前基础 URL
func (c *Client) GetBaseURL() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.baseURL
}

// ==================== 内置 WebSocket Dialer（无外部依赖）====================

var defaultDialer = &wsDialer{}

type wsDialer struct{}

func (d *wsDialer) DialContext(ctx context.Context, urlStr string, httpHeader http.Header) (wsConn, *http.Response, error) {
	u, err := url.Parse(urlStr)
	if err != nil {
		return nil, nil, err
	}

	host := u.Host
	if _, port, _ := net.SplitHostPort(host); port == "" {
		if u.Scheme == "wss" {
			host += ":443"
		} else {
			host += ":80"
		}
	}

	var conn net.Conn
	dialer := &net.Dialer{}
	conn, err = dialer.DialContext(ctx, "tcp", host)
	if err != nil {
		return nil, nil, err
	}

	// 构建 WebSocket 握手请求
	key := generateWSKey()
	reqHeader := make(http.Header)
	reqHeader.Set("Upgrade", "websocket")
	reqHeader.Set("Connection", "Upgrade")
	reqHeader.Set("Sec-WebSocket-Key", key)
	reqHeader.Set("Sec-WebSocket-Version", "13")
	reqHeader.Set("Host", host)
	for k, v := range httpHeader {
		reqHeader[k] = v
	}
	if u.RawQuery != "" {
		reqHeader.Set("GET", u.Path+"?"+u.RawQuery)
	} else {
		reqHeader.Set("GET", u.Path)
	}

	// 发送握手请求
	var reqBuf bytes.Buffer
	fmt.Fprintf(&reqBuf, "GET %s HTTP/1.1\r\n", reqHeader.Get("GET"))
	reqHeader.Write(&reqBuf)
	reqBuf.WriteString("\r\n")

	if _, err := conn.Write(reqBuf.Bytes()); err != nil {
		conn.Close()
		return nil, nil, err
	}

	// 读取握手响应
	br := bufio.NewReader(conn)
	req, _ := http.NewRequest("GET", urlStr, nil)
	resp, err := http.ReadResponse(br, req)
	if err != nil {
		conn.Close()
		return nil, nil, fmt.Errorf("WS 握手响应失败: %w", err)
	}

	if resp.StatusCode != 101 {
		conn.Close()
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return nil, resp, fmt.Errorf("WS 握手失败: status %s: %s", resp.Status, string(body))
	}

	return &basicWsConn{conn: conn}, resp, nil
}

func generateWSKey() string {
	b := make([]byte, 16)
	rand.Read(b)
	return base64.StdEncoding.EncodeToString(b)
}

// wsConn 接口（兼容 gorilla/websocket）
type wsConn interface {
	ReadMessage([]byte) (int, error)
	WriteMessage(int, []byte) error
	Close() error
	SetReadDeadline(time.Time) error
}

type basicWsConn struct {
	conn net.Conn
	rbuf  bytes.Buffer
}

const (
	wsOpContinuation = 0x0
	wsOpText         = 0x1
	wsOpBinary       = 0x2
	wsOpClose        = 0x8
	wsOpPing         = 0x9
	wsOpPong         = 0xa
)

func (c *basicWsConn) ReadMessage(buf []byte) (int, error) {
	// 读取帧头（2 字节基础 + 可选扩展长度 + 掩码）
	header := make([]byte, 2)
	if _, err := io.ReadFull(c.conn, header); err != nil {
		return 0, err
	}

	opcode := header[0] & 0x0f
	masked := (header[1] & 0x80) != 0
	payloadLen := uint64(header[1] & 0x7f)

	switch payloadLen {
	case 126:
		ext := make([]byte, 2)
		io.ReadFull(c.conn, ext)
		payloadLen = uint64(ext[0])<<8 | uint64(ext[1])
	case 127:
		ext := make([]byte, 8)
		io.ReadFull(c.conn, ext)
		payloadLen = uint64(ext[0])<<56 | uint64(ext[1])<<48 | uint64(ext[2])<<40 | uint64(ext[3])<<32 |
			uint64(ext[4])<<24 | uint64(ext[5])<<16 | uint64(ext[6])<<8 | uint64(ext[7])
	}

	var maskKey [4]byte
	if masked {
		io.ReadFull(c.conn, maskKey[:])
	}

	if int(payloadLen) > len(buf) {
		payloadLen = uint64(len(buf))
	}

	data := buf[:payloadLen]
	io.ReadFull(c.conn, data)

	if masked {
		for i := range data {
			data[i] ^= maskKey[i%4]
		}
	}

	switch opcode {
	case wsOpClose:
		c.Close()
		return 0, fmt.Errorf("server sent close frame")
	case wsOpPing:
		c.WriteMessage(wsOpPong, data)
		return c.ReadMessage(buf)
	default:
		// 文本/二帧/续帧：返回数据
		if opcode == wsOpText || opcode == wsOpBinary {
			return int(payloadLen), nil
		}
		// 续帧：继续读并追加到 rbuf
		c.rbuf.Write(data)
		n, err := c.ReadMessage(buf[:cap(data)])
		if err != nil {
			return int(payloadLen), nil
		}
		total := copy(data, c.rbuf.Bytes())
		copy(data[total:], buf[:n])
		return total + n, nil
	}
}

func (c *basicWsConn) WriteMessage(opcode int, data []byte) error {
	var header [10]byte
	var nHeader int

	header[0] = 0x80 | byte(opcode) // FIN + opcode

	length := len(data)
	switch {
	case length < 126:
		header[1] = byte(length)
		nHeader = 2
	case length < 65536:
		header[1] = 126
		header[2] = byte(length >> 8)
		header[3] = byte(length)
		nHeader = 4
	default:
		header[1] = 127
		for i := 8; i >= 1; i-- {
			header[nHeader+9-i] = byte(length >> ((8 - i) * 8))
		}
		nHeader = 10
	}

	if _, err := c.conn.Write(header[:nHeader]); err != nil {
		return err
	}
	if len(data) > 0 {
		_, err := c.conn.Write(data)
		return err
	}
	return nil
}

func (c *basicWsConn) Close() error { return c.conn.Close() }
func (c *basicWsConn) SetReadDeadline(t time.Time) error { return c.conn.SetReadDeadline(t) }

// basicWsConn 实现 wsConn 接口
