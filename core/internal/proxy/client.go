// Package proxy 封装 Mihomo/Clash RESTful API 客户端，提供代理管理的完整能力。
// 支持：策略组/节点管理、延迟测试、连接控制、实时数据流(WebSocket)、规则查看、配置修改。
package proxy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"go.uber.org/zap"
)

// DefaultMihomoPort Mihomo API 默认端口
const DefaultMihomoPort = 9090

// DefaultLatencyTestURL 默认延迟测试地址
const DefaultLatencyTestURL = "http://www.gstatic.com/generate_204"

// Config Mihomo 连接配置
type Config struct {
	Address string `json:"address"` // 如 "http://127.0.0.1:9090"
	Secret  string `json:"secret"`  // API 密钥（可为空）

	LatencyTestURL string `json:"latency_test_url"` // 延迟测试 URL
	LatencyTimeout int    `json:"latency_timeout"`  // 延迟超时（毫秒），默认 5000
	LatencyLow     int    `json:"latency_low"`      // 低延迟阈值（毫秒），默认 200
	LatencyMedium  int    `json:"latency_medium"`   // 中延迟阈值（毫秒），默认 500
}

// DefaultConfig 返回本机 Mihomo 控制器的默认配置。
func DefaultConfig() *Config {
	return &Config{
		Address:        "http://127.0.0.1:9090",
		Secret:         "",
		LatencyTestURL: DefaultLatencyTestURL,
		LatencyTimeout: 5000,
		LatencyLow:     200,
		LatencyMedium:  500,
	}
}

// Client 是 Mihomo API 客户端
type Client struct {
	cfg    *Config
	http   *http.Client
	logger *zap.SugaredLogger

	mu      sync.RWMutex
	baseURL string // "http://host:port"
	version string // 缓存的版本信息
}

// NewClient 创建 Mihomo API 客户端
func NewClient(cfg *Config) (*Client, error) {
	if cfg == nil {
		cfg = DefaultConfig()
	}
	cfg = cloneConfig(cfg)
	if err := cfg.normalizeAndValidate(); err != nil {
		return nil, err
	}

	logger, _ := zap.NewProduction()
	baseURL := cfg.Address

	c := &Client{
		cfg:     cfg,
		http:    &http.Client{Timeout: 15 * time.Second},
		logger:  logger.Sugar(),
		baseURL: baseURL,
	}
	return c, nil
}

// doRequest 执行带认证的 HTTP 请求
func (c *Client) doRequest(method, path string, body interface{}) ([]byte, int, error) {
	return c.doRequestContext(context.Background(), method, path, body)
}

func (c *Client) doRequestContext(ctx context.Context, method, path string, body interface{}) ([]byte, int, error) {
	var bodyReader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, 0, fmt.Errorf("序列化请求体失败: %w", err)
		}
		bodyReader = bytes.NewReader(data)
	}

	c.mu.RLock()
	reqURL := c.baseURL + path
	secret := c.cfg.Secret
	c.mu.RUnlock()
	req, err := http.NewRequestWithContext(ctx, method, reqURL, bodyReader)
	if err != nil {
		return nil, 0, fmt.Errorf("创建请求失败: %w", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
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

func (c *Client) requestOK(method, path string, body interface{}) ([]byte, error) {
	data, code, err := c.doRequest(method, path, body)
	if err != nil {
		return data, err
	}
	if code >= http.StatusBadRequest {
		return data, fmt.Errorf("API 错误 %d: %s", code, strings.TrimSpace(string(data)))
	}
	return data, nil
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
	Meta       bool   `json:"meta"`
	Version    string `json:"version"`
	Premium    bool   `json:"premium"`
	Foundation bool   `json:"foundation"`
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
	Name     string         `json:"name"`
	Type     string         `json:"type"`    // Selector/Fallback/URLTest/LoadBalance/Smart/PassThrough/Reject/Compatible/Unknown
	All      []string       `json:"all"`     // 可选节点列表
	Now      string         `json:"now"`     // 当前选中节点
	History  []DelayHistory `json:"history"` // 延迟历史
	Alive    bool           `json:"alive"`
	Uptime   uint64         `json:"uptime"`
	Provider string         `json:"provider"`

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

type GroupDelayResponse struct {
	Delays map[string]int64 `json:"delays"`
}

// TestProxyDelay 测试单个节点延迟
func (c *Client) TestProxyDelay(proxyName string) (*DelayResponse, error) {
	testURL := c.cfg.LatencyTestURL
	timeout := c.cfg.LatencyTimeout
	path := fmt.Sprintf("/proxies/%s/delay?url=%s&timeout=%d",
		url.PathEscape(proxyName), url.QueryEscape(testURL), timeout)
	data, err := c.requestOK(http.MethodGet, path, nil)
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
func (c *Client) TestGroupDelay(groupName string) (*GroupDelayResponse, error) {
	testURL := c.cfg.LatencyTestURL
	timeout := c.cfg.LatencyTimeout
	path := fmt.Sprintf("/group/%s/delay?url=%s&timeout=%d",
		url.PathEscape(groupName), url.QueryEscape(testURL), timeout)
	data, code, err := c.doRequest("GET", path, nil)
	if err != nil {
		return nil, err
	}
	if code >= http.StatusBadRequest {
		return nil, fmt.Errorf("API 错误 %d: %s", code, strings.TrimSpace(string(data)))
	}
	var delays map[string]int64
	if err := json.Unmarshal(data, &delays); err != nil {
		return nil, fmt.Errorf("解析组延迟结果失败: %w", err)
	}
	return &GroupDelayResponse{Delays: delays}, nil
}

// ==================== Provider ====================

// ProxyProvidersResponse 代理 Provider 列表
type ProxyProvidersResponse struct {
	Providers map[string]ProxyProviderInfo `json:"providers"`
}

// ProxyProviderInfo 代理 Provider 信息
type ProxyProviderInfo struct {
	Name             string            `json:"name"`
	Type             string            `json:"type,omitempty"`
	VehicleType      string            `json:"vehicleType,omitempty"`
	UpdatedAt        time.Time         `json:"updatedAt"`
	TestURL          string            `json:"testUrl,omitempty"`
	Proxies          []ProxyInfo       `json:"proxies,omitempty"`
	ProxyCount       int               `json:"proxy_count"`
	SubscriptionInfo *SubscriptionInfo `json:"subscriptionInfo,omitempty"`
}

type SubscriptionInfo struct {
	Download int64 `json:"Download"`
	Upload   int64 `json:"Upload"`
	Total    int64 `json:"Total"`
	Expire   int64 `json:"Expire"`
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
	for name, provider := range r.Providers {
		if provider.Name == "" {
			provider.Name = name
		}
		provider.ProxyCount = len(provider.Proxies)
		provider.Proxies = nil
		r.Providers[name] = provider
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
	_, err := c.requestOK(http.MethodGet,
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
	Type    string   `json:"type"`
	Payload string   `json:"payload"`
	Proxy   string   `json:"proxy"`
	Chains  []string `json:"chains"`
	Size    int64    `json:"size"`
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
	Name        string    `json:"name"`
	Type        string    `json:"type"`
	Behavior    string    `json:"behavior"`
	Format      string    `json:"format,omitempty"`
	RuleCount   int       `json:"ruleCount"`
	UpdatedAt   time.Time `json:"updatedAt"`
	URL         string    `json:"url,omitempty"`
	VehicleType string    `json:"vehicleType,omitempty"`
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
	for name, provider := range r.Providers {
		if provider.Name == "" {
			provider.Name = name
		}
		r.Providers[name] = provider
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
	Mode                  string    `json:"mode"` // global/direct/rule
	ModeList              []string  `json:"mode-list,omitempty"`
	Modes                 []string  `json:"modes,omitempty"`
	LogLevel              string    `json:"log-level"`
	AllowLan              bool      `json:"allow-lan"`
	BindAddress           string    `json:"bind-address"`
	IPv6                  bool      `json:"ipv6"`
	ExternalController    string    `json:"external-controller"`
	Secret                string    `json:"-"`
	Tun                   TunConfig `json:"tun"`
	MixedPort             int       `json:"mixed-port"`
	RedirPort             int       `json:"redir-port"`
	TProxyPort            int       `json:"tproxy-port"`
	SocksPort             int       `json:"socks-port"`
	Port                  int       `json:"port"`
	ExternalUI            string    `json:"external-ui"`
	ExternalUIDownloadURL string    `json:"external-ui-url"`
}

type TunConfig struct {
	Enable bool `json:"enable"`
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
	return c.PatchConfigs(map[string]interface{}{"tun": map[string]bool{"enable": enable}})
}

// FlushFakeIP 清空 FakeIP 缓存
func (c *Client) FlushFakeIP() error {
	_, err := c.requestOK(http.MethodPost, "/cache/fakeip/flush", nil)
	return err
}

// FlushDNSCache 清空 DNS 缓存
func (c *Client) FlushDNSCache() error {
	_, err := c.requestOK(http.MethodPost, "/cache/dns/flush", nil)
	return err
}

// ReloadConfigs 重载配置文件
func (c *Client) ReloadConfigs() error {
	_, err := c.put("/configs?reload=true", map[string]string{"path": "", "payload": ""})
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
	_, err := c.requestOK(http.MethodPost, "/restart", nil)
	return err
}

// UpgradeCore 升级核心
func (c *Client) UpgradeCore(channel string) error {
	path := "/upgrade"
	if channel != "" {
		path += "?channel=" + channel
	}
	_, err := c.requestOK(http.MethodPost, path, nil)
	return err
}

// UpdateGeoData 更新 GeoIP/GeoSite 数据库
func (c *Client) UpdateGeoData() error {
	_, err := c.requestOK(http.MethodPost, "/configs/geo", nil)
	return err
}

// ==================== 连接管理 ====================// ConnectionsResponse 活跃连接列表响应
type ConnectionsResponse struct {
	DownloadTotal int64              `json:"downloadTotal"`
	UploadTotal   int64              `json:"uploadTotal"`
	Connections   []ConnectionDetail `json:"connections"`
}

// ConnectionDetail 单个连接详情
type ConnectionDetail struct {
	ID            string             `json:"id"`
	Metadata      ConnectionMetadata `json:"metadata"`
	Upload        int64              `json:"upload"`
	Download      int64              `json:"download"`
	Start         time.Time          `json:"start"`
	Chains        []string           `json:"chains"`
	Rule          string             `json:"rule"`
	RulePayload   string             `json:"rulePayload"`
	UploadSpeed   int64              `json:"uploadSpeed"`
	DownloadSpeed int64              `json:"downloadSpeed"`
	Alive         bool               `json:"alive"`
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
	return c.subscribeWS(ctx, c.websocketURL("/connections"))
}

// SubscribeTraffic 订阅实时流量统计（WebSocket）
func (c *Client) SubscribeTraffic(ctx context.Context) (<-chan WSMessage, context.CancelFunc, error) {
	return c.subscribeWS(ctx, c.websocketURL("/traffic"))
}

// SubscribeLogs 订阅实时日志（WebSocket）
func (c *Client) SubscribeLogs(ctx context.Context, logLevel string) (<-chan WSMessage, context.CancelFunc, error) {
	wsURL := c.websocketURL("/logs")
	if logLevel != "" {
		wsURL += "?level=" + url.QueryEscape(logLevel)
	}
	return c.subscribeWS(ctx, wsURL)
}

func (c *Client) websocketURL(path string) string {
	c.mu.RLock()
	baseURL := c.baseURL
	c.mu.RUnlock()
	baseURL = strings.Replace(baseURL, "https://", "wss://", 1)
	baseURL = strings.Replace(baseURL, "http://", "ws://", 1)
	return baseURL + path
}

// subscribeWS 通用 WebSocket 订阅
func (c *Client) subscribeWS(ctx context.Context, wsURL string) (<-chan WSMessage, context.CancelFunc, error) {
	ctx2, cancel := context.WithCancel(ctx)
	ch := make(chan WSMessage, 64)
	go func() {
		defer close(ch)
		backoff := time.Second
		for {
			if ctx2.Err() != nil {
				return
			}

			header := http.Header{}
			c.mu.RLock()
			secret := c.cfg.Secret
			c.mu.RUnlock()
			if secret != "" {
				header.Set("Authorization", "Bearer "+secret)
			}
			conn, resp, err := websocket.DefaultDialer.DialContext(ctx2, wsURL, header)
			if err != nil {
				connectionError := fmt.Errorf("WebSocket 连接失败: %w", err)
				if resp != nil {
					connectionError = fmt.Errorf("WebSocket 连接失败 (%s): %w", resp.Status, err)
				}
				c.sendWSMessage(ctx2, ch, WSMessage{Error: connectionError})
				select {
				case <-ctx2.Done():
					return
				case <-time.After(backoff):
					if backoff < 8*time.Second {
						backoff *= 2
					}
					continue
				}
			}
			backoff = time.Second
			connectionFinished := make(chan struct{})
			go func() {
				select {
				case <-ctx2.Done():
					_ = conn.Close()
				case <-connectionFinished:
				}
			}()

			for {
				_ = conn.SetReadDeadline(time.Now().Add(90 * time.Second))
				_, message, err := conn.ReadMessage()
				if err != nil {
					_ = conn.Close()
					if ctx2.Err() == nil {
						c.logger.Debugf("WS 断开(%s): %v", wsURL, err)
					}
					break
				}
				if !c.sendWSMessage(ctx2, ch, WSMessage{Data: append(json.RawMessage(nil), message...)}) {
					_ = conn.Close()
					close(connectionFinished)
					return
				}
			}
			close(connectionFinished)
		}
	}()

	return ch, cancel, nil
}

func (c *Client) sendWSMessage(ctx context.Context, ch chan<- WSMessage, message WSMessage) bool {
	select {
	case ch <- message:
		return true
	case <-ctx.Done():
		return false
	}
}

// Ping 测试连通性（轻量级健康检查）
func (c *Client) Ping() error {
	_, err := c.get("/version")
	return err
}

func (c *Client) PingContext(ctx context.Context) error {
	data, code, err := c.doRequestContext(ctx, http.MethodGet, "/version", nil)
	if err != nil {
		return err
	}
	if code >= 400 {
		return fmt.Errorf("Mihomo API %d: %s", code, strings.TrimSpace(string(data)))
	}
	return nil
}

// SetAddress 动态切换目标地址
func (c *Client) SetAddress(addr string) {
	baseURL, err := normalizeControllerURL(addr)
	if err != nil {
		return
	}
	c.mu.Lock()
	c.baseURL = baseURL
	c.cfg.Address = baseURL
	c.mu.Unlock()
}

// GetBaseURL 获取当前基础 URL
func (c *Client) GetBaseURL() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.baseURL
}
