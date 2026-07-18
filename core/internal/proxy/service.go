// Package proxy - 服务层：管理 Mihomo 客户端生命周期，提供 daemon HTTP API 桥接。
package proxy

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"sync"
	"time"

	"go.uber.org/zap"
)

// Service 管理代理模块的完整生命周期
type Service struct {
	mu          sync.RWMutex
	client      *Client
	cfg         *Config
	configPath  string
	logger      *zap.SugaredLogger
	running     bool
	connected   bool
	lastError   string
	lastChecked time.Time
	logCancel   context.CancelFunc
	logs        []ProxyLogEntry
}

type Status struct {
	Running     bool   `json:"running"`
	Connected   bool   `json:"connected"`
	Address     string `json:"address"`
	BaseURL     string `json:"base_url,omitempty"`
	LastError   string `json:"last_error,omitempty"`
	LastChecked string `json:"last_checked,omitempty"`
}

type ProxyLogEntry struct {
	Time    string `json:"time"`
	Level   string `json:"level"`
	Payload string `json:"payload"`
}

// New 创建代理服务（不自动连接）
func New(cfg *Config) (*Service, error) {
	if cfg == nil {
		cfg = DefaultConfig()
	}
	cfg = cloneConfig(cfg)
	if err := cfg.normalizeAndValidate(); err != nil {
		return nil, err
	}
	logger, _ := zap.NewProduction()
	return &Service{cfg: cfg, logger: logger.Sugar()}, nil
}

func NewPersistent(cfg *Config, configPath string) (*Service, error) {
	service, err := New(cfg)
	if err != nil {
		return nil, err
	}
	service.configPath = configPath
	return service, nil
}

// Start 初始化 Mihomo 客户端并测试连通性
func (s *Service) Start() error {
	s.mu.Lock()
	if s.running {
		s.mu.Unlock()
		return nil
	}
	cfg := cloneConfig(s.cfg)
	s.mu.Unlock()

	client, err := NewClient(cfg)
	if err != nil {
		return fmt.Errorf("创建 Mihomo 客户端失败: %w", err)
	}
	s.mu.Lock()
	s.client = client
	s.running = true
	s.connected = false
	s.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := s.Check(ctx); err != nil {
		s.logger.Warnf("Mihomo 连通性检查失败(非致命): %v", err)
	}
	return nil
}

// Stop 停止服务
func (s *Service) Stop() {
	s.mu.Lock()
	cancelLogs := s.logCancel
	s.logCancel = nil
	s.client = nil
	s.running = false
	s.connected = false
	s.mu.Unlock()
	if cancelLogs != nil {
		cancelLogs()
	}
}

// GetClient 获取 Mihomo 客户端（只读）
func (s *Service) GetClient() *Client {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.client
}

// IsRunning 返回服务是否运行中
func (s *Service) IsRunning() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.running
}

func (s *Service) Check(ctx context.Context) error {
	s.mu.RLock()
	client := s.client
	running := s.running
	s.mu.RUnlock()
	if !running || client == nil {
		return fmt.Errorf("代理服务未运行")
	}
	err := client.PingContext(ctx)
	s.mu.Lock()
	s.connected = err == nil
	s.lastChecked = time.Now()
	if err != nil {
		s.lastError = err.Error()
	} else {
		s.lastError = ""
	}
	s.mu.Unlock()
	return err
}

func (s *Service) Status() Status {
	s.mu.RLock()
	defer s.mu.RUnlock()
	status := Status{
		Running: s.running, Connected: s.connected,
		LastError: s.lastError,
	}
	if s.cfg != nil {
		status.Address = s.cfg.Address
	}
	if s.client != nil {
		status.BaseURL = s.client.GetBaseURL()
	}
	if !s.lastChecked.IsZero() {
		status.LastChecked = s.lastChecked.Format(time.RFC3339)
	}
	return status
}

func (s *Service) Settings() PublicSettings {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return publicSettings(s.cfg)
}

// UpdateConfig 动态更新配置（会重建客户端）
func (s *Service) UpdateConfig(newCfg *Config) error {
	newCfg = cloneConfig(newCfg)
	if err := newCfg.normalizeAndValidate(); err != nil {
		return err
	}
	client, err := NewClient(newCfg)
	if err != nil {
		return err
	}
	if err := saveConfig(s.configPath, newCfg); err != nil {
		return err
	}
	s.mu.Lock()
	cancelLogs := s.logCancel
	s.logCancel = nil
	s.logs = nil
	s.cfg = newCfg
	s.client = client
	s.running = true
	s.connected = false
	s.lastError = "尚未测试连接"
	s.mu.Unlock()
	if cancelLogs != nil {
		cancelLogs()
	}
	return nil
}

func (s *Service) startLogStream(client *Client) {
	ctx, cancel := context.WithCancel(context.Background())
	s.mu.Lock()
	if s.client != client || !s.connected {
		s.mu.Unlock()
		cancel()
		return
	}
	previousCancel := s.logCancel
	s.logCancel = cancel
	s.mu.Unlock()
	if previousCancel != nil {
		previousCancel()
	}

	messages, stop, err := client.SubscribeLogs(ctx, "info")
	if err != nil {
		cancel()
		s.appendProxyLog(client, ProxyLogEntry{
			Time: time.Now().Format(time.RFC3339), Level: "error", Payload: err.Error(),
		})
		return
	}
	go func() {
		defer stop()
		lastError := ""
		for message := range messages {
			if message.Error != nil {
				if message.Error.Error() != lastError {
					lastError = message.Error.Error()
					s.appendProxyLog(client, ProxyLogEntry{
						Time: time.Now().Format(time.RFC3339), Level: "error", Payload: lastError,
					})
				}
				continue
			}
			lastError = ""
			var raw struct {
				Type    string `json:"type"`
				Payload string `json:"payload"`
			}
			if err := json.Unmarshal(message.Data, &raw); err != nil {
				raw.Type = "info"
				raw.Payload = string(message.Data)
			}
			if raw.Type == "" {
				raw.Type = "info"
			}
			s.appendProxyLog(client, ProxyLogEntry{
				Time: time.Now().Format(time.RFC3339), Level: raw.Type, Payload: raw.Payload,
			})
		}
	}()
}

func (s *Service) EnsureLogStream() {
	s.mu.RLock()
	client := s.client
	connected := s.connected
	started := s.logCancel != nil
	s.mu.RUnlock()
	if client == nil || !connected || started {
		return
	}
	s.startLogStream(client)
}

func (s *Service) appendProxyLog(client *Client, entry ProxyLogEntry) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.client != client {
		return
	}
	s.logs = append(s.logs, entry)
	if len(s.logs) > 300 {
		s.logs = append([]ProxyLogEntry(nil), s.logs[len(s.logs)-300:]...)
	}
}

func (s *Service) Logs(limit int) []ProxyLogEntry {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if limit <= 0 || limit > len(s.logs) {
		limit = len(s.logs)
	}
	start := len(s.logs) - limit
	result := append([]ProxyLogEntry(nil), s.logs[start:]...)
	if result == nil {
		return []ProxyLogEntry{}
	}
	return result
}

func (s *Service) ApplySettings(patch SettingsPatch) (Status, error) {
	s.mu.RLock()
	next := cloneConfig(s.cfg)
	s.mu.RUnlock()
	if patch.Address != nil {
		next.Address = *patch.Address
	}
	if patch.Secret != nil {
		next.Secret = *patch.Secret
	}
	if patch.LatencyTestURL != nil {
		next.LatencyTestURL = *patch.LatencyTestURL
	}
	if patch.LatencyTimeout != nil {
		next.LatencyTimeout = *patch.LatencyTimeout
	}
	if patch.LatencyLow != nil {
		next.LatencyLow = *patch.LatencyLow
	}
	if patch.LatencyMedium != nil {
		next.LatencyMedium = *patch.LatencyMedium
	}
	if err := s.UpdateConfig(next); err != nil {
		return s.Status(), err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = s.Check(ctx)
	return s.Status(), nil
}

// ==================== Daemon HTTP Handlers ====================
// 以下 handler 函数供 api 包注册路由使用。

// H 版本信息
type H struct {
	Svc *Service
}

type RuntimeConfigPatch struct {
	Mode        *string         `json:"mode"`
	LogLevel    *string         `json:"log-level"`
	AllowLAN    *bool           `json:"allow-lan"`
	BindAddress *string         `json:"bind-address"`
	IPv6        *bool           `json:"ipv6"`
	Tun         *TunConfigPatch `json:"tun"`
	Port        *int            `json:"port"`
	SocksPort   *int            `json:"socks-port"`
	RedirPort   *int            `json:"redir-port"`
	TProxyPort  *int            `json:"tproxy-port"`
	MixedPort   *int            `json:"mixed-port"`
}

type TunConfigPatch struct {
	Enable *bool `json:"enable"`
}

func (patch RuntimeConfigPatch) values() (map[string]interface{}, error) {
	result := map[string]interface{}{}
	if patch.Mode != nil {
		if *patch.Mode == "" {
			return nil, fmt.Errorf("mode 不能为空")
		}
		result["mode"] = *patch.Mode
	}
	if patch.LogLevel != nil {
		result["log-level"] = *patch.LogLevel
	}
	if patch.AllowLAN != nil {
		result["allow-lan"] = *patch.AllowLAN
	}
	if patch.BindAddress != nil {
		result["bind-address"] = *patch.BindAddress
	}
	if patch.IPv6 != nil {
		result["ipv6"] = *patch.IPv6
	}
	if patch.Tun != nil && patch.Tun.Enable != nil {
		result["tun"] = map[string]bool{"enable": *patch.Tun.Enable}
	}
	ports := []struct {
		key   string
		value *int
	}{
		{"port", patch.Port},
		{"socks-port", patch.SocksPort},
		{"redir-port", patch.RedirPort},
		{"tproxy-port", patch.TProxyPort},
		{"mixed-port", patch.MixedPort},
	}
	for _, port := range ports {
		if port.value == nil {
			continue
		}
		if *port.value < 0 || *port.value > 65535 {
			return nil, fmt.Errorf("%s 必须在 0 到 65535 之间", port.key)
		}
		result[port.key] = *port.value
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("没有可应用的配置项")
	}
	return result, nil
}

func VersionHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodGet) {
			return
		}
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		client := svc.GetClient()
		if client == nil {
			writeError(w, fmt.Errorf("代理服务未运行"))
			return
		}
		v, err := client.GetVersion()
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, v)
	}
}

// ProxiesHandler 获取所有代理
func ProxiesHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodGet) {
			return
		}
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		client := svc.GetClient()
		if client == nil {
			writeError(w, fmt.Errorf("代理服务未运行"))
			return
		}
		p, err := client.GetProxies()
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, p)
	}
}

// SelectProxyHandler 切换策略组节点
func SelectProxyHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodPost) {
			return
		}
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		client := svc.GetClient()
		if client == nil {
			writeError(w, fmt.Errorf("代理服务未运行"))
			return
		}

		var req struct {
			Group string `json:"group"`
			Name  string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, fmt.Errorf("参数错误: %w", err))
			return
		}
		if req.Group == "" || req.Name == "" {
			writeError(w, fmt.Errorf("group 和 name 不能为空"))
			return
		}
		err := client.SelectProxy(req.Group, req.Name)
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	}
}

// DelayTestHandler 延迟测试
func DelayTestHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodGet) {
			return
		}
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		client := svc.GetClient()
		if client == nil {
			writeError(w, fmt.Errorf("代理服务未运行"))
			return
		}

		name := r.URL.Query().Get("name")
		group := r.URL.Query().Get("group")
		if name == "" && group == "" {
			writeError(w, fmt.Errorf("name 或 group 参数必填"))
			return
		}

		if name != "" {
			result, err := client.TestProxyDelay(name)
			if err != nil {
				writeError(w, err)
				return
			}
			writeJSON(w, result)
			return
		}
		result, err := client.TestGroupDelay(group)
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, result)
	}
}

// ProvidersHandler 获取 Provider 列表
func ProvidersHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodGet) {
			return
		}
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		client := svc.GetClient()
		if client == nil {
			writeError(w, fmt.Errorf("代理服务未运行"))
			return
		}
		p, err := client.GetProxyProviders()
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, p)
	}
}

// UpdateProviderHandler 更新订阅
func UpdateProviderHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodPost) {
			return
		}
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		client := svc.GetClient()
		if client == nil {
			writeError(w, fmt.Errorf("代理服务未运行"))
			return
		}

		name := r.URL.Query().Get("name")
		if name == "" {
			writeError(w, fmt.Errorf("name 不能为空"))
			return
		}
		err := client.UpdateProxyProvider(name)
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	}
}

// ProviderHealthCheckHandler 触发订阅内全部节点的健康检查。
func ProviderHealthCheckHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodPost) {
			return
		}
		client := serviceClient(w, svc)
		if client == nil {
			return
		}
		name := r.URL.Query().Get("name")
		if name == "" {
			writeError(w, fmt.Errorf("name 不能为空"))
			return
		}
		if err := client.HealthCheckProvider(name); err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	}
}

// ConnectionsHandler 获取活跃连接快照
func ConnectionsHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodGet) {
			return
		}
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		client := svc.GetClient()
		if client == nil {
			writeError(w, fmt.Errorf("代理服务未运行"))
			return
		}
		c, err := client.GetConnections()
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, c)
	}
}

// CloseConnectionHandler 关闭单个连接
func CloseConnectionHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodPost) {
			return
		}
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		client := svc.GetClient()
		if client == nil {
			writeError(w, fmt.Errorf("代理服务未运行"))
			return
		}

		id := r.URL.Query().Get("id")
		if id == "" {
			writeError(w, fmt.Errorf("id 不能为空"))
			return
		}
		err := client.CloseConnection(id)
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	}
}

// CloseAllConnectionsHandler 关闭全部连接
func CloseAllConnectionsHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodPost) {
			return
		}
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		client := svc.GetClient()
		if client == nil {
			writeError(w, fmt.Errorf("代理服务未运行"))
			return
		}
		err := client.CloseAllConnections()
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	}
}

// RulesHandler 获取规则列表
func RulesHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodGet) {
			return
		}
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		client := svc.GetClient()
		if client == nil {
			writeError(w, fmt.Errorf("代理服务未运行"))
			return
		}
		rules, err := client.GetRules()
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, rules)
	}
}

// RuleProvidersHandler 获取规则 Provider 列表。
func RuleProvidersHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodGet) {
			return
		}
		client := serviceClient(w, svc)
		if client == nil {
			return
		}
		providers, err := client.GetRuleProviders()
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, providers)
	}
}

// UpdateRuleProviderHandler 更新指定规则 Provider。
func UpdateRuleProviderHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodPost) {
			return
		}
		client := serviceClient(w, svc)
		if client == nil {
			return
		}
		name := r.URL.Query().Get("name")
		if name == "" {
			writeError(w, fmt.Errorf("name 不能为空"))
			return
		}
		if err := client.UpdateRuleProvider(name); err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	}
}

// ConfigsHandler 获取/修改运行配置
func ConfigsHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		client := svc.GetClient()
		if client == nil {
			writeError(w, fmt.Errorf("代理服务未运行"))
			return
		}

		switch r.Method {
		case http.MethodGet:
			cfg, err := client.GetConfigs()
			if err != nil {
				writeError(w, err)
				return
			}
			writeJSON(w, cfg)
		case http.MethodPatch:
			var patch RuntimeConfigPatch
			decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64*1024))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&patch); err != nil {
				writeError(w, fmt.Errorf("参数错误: %w", err))
				return
			}
			values, err := patch.values()
			if err != nil {
				writeError(w, err)
				return
			}
			err = client.PatchConfigs(values)
			if err != nil {
				writeError(w, err)
				return
			}
			writeJSON(w, map[string]bool{"ok": true})
		default:
			methodNotAllowed(w, http.MethodGet, http.MethodPatch)
		}
	}
}

// CacheHandler 缓存操作（FakeIP/DNS flush）
func CacheHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodPost) {
			return
		}
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		client := svc.GetClient()
		if client == nil {
			writeError(w, fmt.Errorf("代理服务未运行"))
			return
		}

		action := r.URL.Query().Get("action") // fakeip / dns
		var err error
		switch action {
		case "fakeip":
			err = client.FlushFakeIP()
		case "dns":
			err = client.FlushDNSCache()
		default:
			writeError(w, fmt.Errorf("未知操作: %s", action))
			return
		}
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, map[string]bool{"ok": true})
	}
}

// ActionHandler 执行明确列入白名单的 Mihomo 维护动作。
func ActionHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodPost) {
			return
		}
		client := serviceClient(w, svc)
		if client == nil {
			return
		}
		var request struct {
			Action string `json:"action"`
		}
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16*1024))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&request); err != nil {
			writeError(w, fmt.Errorf("参数错误: %w", err))
			return
		}
		var err error
		switch request.Action {
		case "flush-fakeip":
			err = client.FlushFakeIP()
		case "flush-dns":
			err = client.FlushDNSCache()
		case "reload-configs":
			err = client.ReloadConfigs()
		case "update-geo":
			err = client.UpdateGeoData()
		case "restart-core":
			err = client.RestartCore()
		default:
			writeError(w, fmt.Errorf("未知维护动作: %s", request.Action))
			return
		}
		if err != nil {
			writeError(w, err)
			return
		}
		writeJSON(w, map[string]interface{}{"ok": true, "action": request.Action})
	}
}

// DNSQueryHandler 通过 Mihomo 的 DNS 引擎查询域名。
func DNSQueryHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodGet) {
			return
		}
		client := serviceClient(w, svc)
		if client == nil {
			return
		}
		name := r.URL.Query().Get("name")
		queryType := r.URL.Query().Get("type")
		if name == "" {
			writeError(w, fmt.Errorf("name 不能为空"))
			return
		}
		if queryType == "" {
			queryType = "A"
		}
		switch queryType {
		case "A", "AAAA", "CNAME", "MX", "NS", "TXT", "SRV", "PTR":
		default:
			writeError(w, fmt.Errorf("不支持的 DNS 查询类型: %s", queryType))
			return
		}
		data, err := client.DNSQuery(name, queryType)
		if err != nil {
			writeError(w, err)
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write(data)
	}
}

// ProxyLogsHandler 返回 daemon 缓存的 Mihomo 实时日志。
func ProxyLogsHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodGet) {
			return
		}
		if svc == nil {
			writeErrorStatus(w, http.StatusServiceUnavailable, fmt.Errorf("代理服务未初始化"))
			return
		}
		limit := 200
		if raw := r.URL.Query().Get("n"); raw != "" {
			parsed, err := strconv.Atoi(raw)
			if err != nil || parsed < 1 || parsed > 300 {
				writeError(w, fmt.Errorf("n 必须在 1 到 300 之间"))
				return
			}
			limit = parsed
		}
		svc.EnsureLogStream()
		logs := svc.Logs(limit)
		writeJSON(w, map[string]interface{}{"logs": logs, "count": len(logs)})
	}
}

// ProxyStatusHandler 返回代理模块状态（不依赖 Mihomo 连接）
func ProxyStatusHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !requireMethod(w, r, http.MethodGet) {
			return
		}
		if svc == nil {
			writeJSON(w, Status{LastError: "代理服务未初始化"})
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
		defer cancel()
		_ = svc.Check(ctx)
		writeJSON(w, svc.Status())
	}
}

// SettingsHandler 获取或保存 WgSense 的 Mihomo 控制器连接设置。
func SettingsHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if svc == nil {
			writeError(w, fmt.Errorf("代理服务未初始化"))
			return
		}
		switch r.Method {
		case http.MethodGet:
			writeJSON(w, map[string]interface{}{
				"settings": svc.Settings(),
				"status":   svc.Status(),
			})
		case http.MethodPatch:
			var patch SettingsPatch
			decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64*1024))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&patch); err != nil {
				writeError(w, fmt.Errorf("参数错误: %w", err))
				return
			}
			status, err := svc.ApplySettings(patch)
			if err != nil {
				writeError(w, err)
				return
			}
			writeJSON(w, map[string]interface{}{
				"settings": svc.Settings(),
				"status":   status,
			})
		default:
			methodNotAllowed(w, http.MethodGet, http.MethodPatch)
		}
	}
}

// ==================== 辅助函数 ====================

func serviceClient(w http.ResponseWriter, svc *Service) *Client {
	if svc == nil {
		writeErrorStatus(w, http.StatusServiceUnavailable, fmt.Errorf("代理服务未初始化"))
		return nil
	}
	client := svc.GetClient()
	if client == nil {
		writeErrorStatus(w, http.StatusServiceUnavailable, fmt.Errorf("代理服务未运行"))
		return nil
	}
	return client
}

func requireMethod(w http.ResponseWriter, r *http.Request, methods ...string) bool {
	for _, method := range methods {
		if r.Method == method {
			return true
		}
	}
	methodNotAllowed(w, methods...)
	return false
}

func methodNotAllowed(w http.ResponseWriter, methods ...string) {
	for _, method := range methods {
		w.Header().Add("Allow", method)
	}
	writeErrorStatus(w, http.StatusMethodNotAllowed, fmt.Errorf("不支持的请求方法"))
}

func writeJSON(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, err error) {
	writeErrorStatus(w, http.StatusBadRequest, err)
}

func writeErrorStatus(w http.ResponseWriter, status int, err error) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}
