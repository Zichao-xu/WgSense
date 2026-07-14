// Package proxy - 服务层：管理 Mihomo 客户端生命周期，提供 daemon HTTP API 桥接。
package proxy

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	"go.uber.org/zap"
)

// Service 管理代理模块的完整生命周期
type Service struct {
	mu      sync.RWMutex
	client  *Client
	cfg     *Config
	logger  *zap.SugaredLogger
	running bool
}

// New 创建代理服务（不自动连接）
func New(cfg *Config) (*Service, error) {
	if cfg == nil {
		cfg = DefaultConfig()
	}
	logger, _ := zap.NewProduction()
	return &Service{cfg: cfg, logger: logger.Sugar()}, nil
}

// Start 初始化 Mihomo 客户端并测试连通性
func (s *Service) Start() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.running {
		return nil
	}

	client, err := NewClient(s.cfg)
	if err != nil {
		return fmt.Errorf("创建 Mihomo 客户端失败: %w", err)
	}

	// 测试连通性
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	done := make(chan error, 1)
	go func() {
		done <- client.Ping()
	}()

	select {
	case <-ctx.Done():
		s.logger.Warnf("Mihomo 连接超时: %s", s.cfg.Address)
		// 不返回错误，允许离线启动
	case err := <-done:
		if err != nil {
			s.logger.Warnf("Mihomo 连通性检查失败(非致命): %v", err)
		} else {
			s.logger.Infof("已连接到 Mihomo: %s", s.cfg.Address)
		}
	}

	s.client = client
	s.running = true
	return nil
}

// Stop 停止服务
func (s *Service) Stop() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.client = nil
	s.running = false
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

// UpdateConfig 动态更新配置（会重建客户端）
func (s *Service) UpdateConfig(newCfg *Config) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	wasRunning := s.running
	if wasRunning {
		s.client = nil
		s.running = false
	}

	s.cfg = newCfg
	client, err := NewClient(s.cfg)
	if err != nil {
		return err
	}
	s.client = client
	s.running = true
	return nil
}

// ==================== Daemon HTTP Handlers ====================
// 以下 handler 函数供 api 包注册路由使用。

// H 版本信息
type H struct {
	Svc *Service
}

func VersionHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := svc.GetClient()
		if client == nil { writeError(w, fmt.Errorf("代理服务未运行")); return }
		v, err := client.GetVersion()
		if err != nil { writeError(w, err); return }
		writeJSON(w, v)
	}
}

// ProxiesHandler 获取所有代理
func ProxiesHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := svc.GetClient()
		if client == nil { writeError(w, fmt.Errorf("代理服务未运行")); return }
		p, err := client.GetProxies()
		if err != nil { writeError(w, err); return }
		writeJSON(w, p)
	}
}

// SelectProxyHandler 切换策略组节点
func SelectProxyHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := svc.GetClient()
		if client == nil { writeError(w, fmt.Errorf("代理服务未运行")); return }

		var req struct {
			Group string `json:"group"`
			Name  string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, fmt.Errorf("参数错误: %w", err)); return
		}
		if req.Group == "" || req.Name == "" {
			writeError(w, fmt.Errorf("group 和 name 不能为空")); return
		}
		err := client.SelectProxy(req.Group, req.Name)
		if err != nil { writeError(w, err); return }
		writeJSON(w, map[string]bool{"ok": true})
	}
}

// DelayTestHandler 延迟测试
func DelayTestHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := svc.GetClient()
		if client == nil { writeError(w, fmt.Errorf("代理服务未运行")); return }

		name := r.URL.Query().Get("name")
		group := r.URL.Query().Get("group")
		if name == "" && group == "" {
			writeError(w, fmt.Errorf("name 或 group 参数必填")); return
		}

		var result *DelayResponse
		var err error
		if name != "" {
			result, err = client.TestProxyDelay(name)
		} else {
			result, err = client.TestGroupDelay(group)
		}
		if err != nil { writeError(w, err); return }
		writeJSON(w, result)
	}
}

// ProvidersHandler 获取 Provider 列表
func ProvidersHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := svc.GetClient()
		if client == nil { writeError(w, fmt.Errorf("代理服务未运行")); return }
		p, err := client.GetProxyProviders()
		if err != nil { writeError(w, err); return }
		writeJSON(w, p)
	}
}

// UpdateProviderHandler 更新订阅
func UpdateProviderHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := svc.GetClient()
		if client == nil { writeError(w, fmt.Errorf("代理服务未运行")); return }

		name := r.URL.Query().Get("name")
		if name == "" {
			writeError(w, fmt.Errorf("name 不能为空")); return
		}
		err := client.UpdateProxyProvider(name)
		if err != nil { writeError(w, err); return }
		writeJSON(w, map[string]bool{"ok": true})
	}
}

// ConnectionsHandler 获取活跃连接快照
func ConnectionsHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := svc.GetClient()
		if client == nil { writeError(w, fmt.Errorf("代理服务未运行")); return }
		c, err := client.GetConnections()
		if err != nil { writeError(w, err); return }
		writeJSON(w, c)
	}
}

// CloseConnectionHandler 关闭单个连接
func CloseConnectionHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := svc.GetClient()
		if client == nil { writeError(w, fmt.Errorf("代理服务未运行")); return }

		id := r.URL.Query().Get("id")
		if id == "" {
			writeError(w, fmt.Errorf("id 不能为空")); return
		}
		err := client.CloseConnection(id)
		if err != nil { writeError(w, err); return }
		writeJSON(w, map[string]bool{"ok": true})
	}
}

// CloseAllConnectionsHandler 关闭全部连接
func CloseAllConnectionsHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := svc.GetClient()
		if client == nil { writeError(w, fmt.Errorf("代理服务未运行")); return }
		err := client.CloseAllConnections()
		if err != nil { writeError(w, err); return }
		writeJSON(w, map[string]bool{"ok": true})
	}
}

// RulesHandler 获取规则列表
func RulesHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := svc.GetClient()
		if client == nil { writeError(w, fmt.Errorf("代理服务未运行")); return }
		rules, err := client.GetRules()
		if err != nil { writeError(w, err); return }
		writeJSON(w, rules)
	}
}

// ConfigsHandler 获取/修改运行配置
func ConfigsHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := svc.GetClient()
		if client == nil { writeError(w, fmt.Errorf("代理服务未运行")); return }

		switch r.Method {
		case "GET":
			cfg, err := client.GetConfigs()
			if err != nil { writeError(w, err); return }
			writeJSON(w, cfg)
		case "PATCH":
			var patch map[string]interface{}
			if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
				writeError(w, fmt.Errorf("参数错误: %w", err)); return
			}
			err := client.PatchConfigs(patch)
			if err != nil { writeError(w, err); return }
			writeJSON(w, map[string]bool{"ok": true})
		default:
			http.Error(w, "Method not allowed", 405)
		}
	}
}

// CacheHandler 缓存操作（FakeIP/DNS flush）
func CacheHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := svc.GetClient()
		if client == nil { writeError(w, fmt.Errorf("代理服务未运行")); return }

		action := r.URL.Query().Get("action") // fakeip / dns
		var err error
		switch action {
		case "fakeip":
			err = client.FlushFakeIP()
		case "dns":
			err = client.FlushDNSCache()
		default:
			writeError(w, fmt.Errorf("未知操作: %s", action)); return
		}
		if err != nil { writeError(w, err); return }
		writeJSON(w, map[string]bool{"ok": true})
	}
}

// ProxyStatusHandler 返回代理模块状态（不依赖 Mihomo 连接）
func ProxyStatusHandler(svc *Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		status := map[string]interface{}{
			"running": svc.IsRunning(),
		}
		if svc.cfg != nil {
			status["address"] = svc.cfg.Address
		}
		if svc.client != nil {
			status["baseURL"] = svc.client.GetBaseURL()
		}
		writeJSON(w, status)
	}
}

// ==================== 辅助函数 ====================

func writeJSON(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, err error) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusBadRequest)
	json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}
