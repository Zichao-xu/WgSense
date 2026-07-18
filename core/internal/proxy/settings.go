package proxy

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

type PublicSettings struct {
	Address        string `json:"address"`
	SecretSet      bool   `json:"secret_set"`
	LatencyTestURL string `json:"latency_test_url"`
	LatencyTimeout int    `json:"latency_timeout"`
	LatencyLow     int    `json:"latency_low"`
	LatencyMedium  int    `json:"latency_medium"`
}

type SettingsPatch struct {
	Address        *string `json:"address"`
	Secret         *string `json:"secret"`
	LatencyTestURL *string `json:"latency_test_url"`
	LatencyTimeout *int    `json:"latency_timeout"`
	LatencyLow     *int    `json:"latency_low"`
	LatencyMedium  *int    `json:"latency_medium"`
}

func LoadConfig(path string) (*Config, error) {
	cfg := DefaultConfig()
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return cfg, nil
	}
	if err != nil {
		return nil, fmt.Errorf("读取代理设置失败: %w", err)
	}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("解析代理设置失败: %w", err)
	}
	if err := cfg.normalizeAndValidate(); err != nil {
		return nil, fmt.Errorf("代理设置无效: %w", err)
	}
	return cfg, nil
}

func saveConfig(path string, cfg *Config) error {
	if path == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("创建代理设置目录失败: %w", err)
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("编码代理设置失败: %w", err)
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".proxy-settings-*")
	if err != nil {
		return fmt.Errorf("创建代理设置临时文件失败: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("保存代理设置失败: %w", err)
	}
	return os.Chmod(path, 0600)
}

func (c *Config) normalizeAndValidate() error {
	if c.Address == "" {
		c.Address = DefaultConfig().Address
	}
	baseURL, err := normalizeControllerURL(c.Address)
	if err != nil {
		return err
	}
	c.Address = baseURL
	if c.LatencyTestURL == "" {
		c.LatencyTestURL = DefaultLatencyTestURL
	}
	testURL, err := url.Parse(c.LatencyTestURL)
	if err != nil || testURL.Host == "" || (testURL.Scheme != "http" && testURL.Scheme != "https") {
		return fmt.Errorf("延迟测试 URL 必须是有效的 HTTP/HTTPS 地址")
	}
	if c.LatencyTimeout == 0 {
		c.LatencyTimeout = 5000
	}
	if c.LatencyTimeout < 500 || c.LatencyTimeout > 120000 {
		return fmt.Errorf("延迟超时必须在 500 到 120000 毫秒之间")
	}
	if c.LatencyLow == 0 {
		c.LatencyLow = 200
	}
	if c.LatencyMedium == 0 {
		c.LatencyMedium = 500
	}
	if c.LatencyLow < 1 || c.LatencyMedium <= c.LatencyLow {
		return fmt.Errorf("中延迟阈值必须大于低延迟阈值")
	}
	return nil
}

func normalizeControllerURL(address string) (string, error) {
	address = strings.TrimSpace(address)
	if address == "" {
		return "", fmt.Errorf("控制器地址不能为空")
	}
	if !strings.Contains(address, "://") {
		address = "http://" + address
	}
	parsed, err := url.Parse(address)
	if err != nil || parsed.Host == "" {
		return "", fmt.Errorf("控制器地址无效")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return "", fmt.Errorf("控制器地址仅支持 HTTP 或 HTTPS")
	}
	if parsed.RawQuery != "" || parsed.Fragment != "" || parsed.User != nil {
		return "", fmt.Errorf("控制器地址不能包含账号、查询参数或片段")
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	return strings.TrimRight(parsed.String(), "/"), nil
}

func cloneConfig(cfg *Config) *Config {
	if cfg == nil {
		return DefaultConfig()
	}
	copy := *cfg
	return &copy
}

func publicSettings(cfg *Config) PublicSettings {
	return PublicSettings{
		Address: cfg.Address, SecretSet: cfg.Secret != "",
		LatencyTestURL: cfg.LatencyTestURL, LatencyTimeout: cfg.LatencyTimeout,
		LatencyLow: cfg.LatencyLow, LatencyMedium: cfg.LatencyMedium,
	}
}
