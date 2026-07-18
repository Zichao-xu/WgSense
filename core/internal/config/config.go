// Package config 定义 WgSense 的运行配置。
package config

// Config 是 WgSense 守护的运行配置。
type Config struct {
	// AutoConnectUntrusted controls whether the daemon may connect WireGuard by
	// itself when the current network is outside trusted prefixes. Manual connect
	// is unaffected.
	AutoConnectUntrusted bool `json:"auto_connect_untrusted"`

	// TrustedNetworkPrefixes are local network prefixes where WireGuard should be
	// kept disconnected, for example office/home LAN prefixes.
	TrustedNetworkPrefixes []string `json:"trusted_network_prefixes"`

	// Deprecated compatibility fields. Keep accepting/emitting them so existing
	// UI builds and config files do not break while the product terminology moves
	// from "home/away" to "trusted/untrusted".
	AutoConnectAway     bool     `json:"auto_connect_away"`
	HomeNetworkPrefixes []string `json:"home_network_prefixes"`

	// IntervalSeconds 是巡检间隔秒数。
	IntervalSeconds int `json:"interval_seconds"`
	// AutoUpGraceSeconds 是自动拉起后的宽限期，防止抖动重连。
	AutoUpGraceSeconds int `json:"auto_up_grace_seconds"`
	// HealthCheckTarget 是假连接探测目标(必须走 WG 才能访问的地址)。
	HealthCheckTarget string `json:"health_check_target"`
	// HealthCheckIntervalSeconds 是假连接探测间隔(每 N 秒探一次)。
	HealthCheckIntervalSeconds int `json:"health_check_interval_seconds"`
}

// Default 返回默认配置。
func Default() Config {
	return Config{
		AutoConnectUntrusted:       false,
		TrustedNetworkPrefixes:     []string{},
		AutoConnectAway:            false,
		HomeNetworkPrefixes:        []string{},
		IntervalSeconds:            10,
		AutoUpGraceSeconds:         20,
		HealthCheckTarget:          "https://1.1.1.1",
		HealthCheckIntervalSeconds: 30,
	}
}

// Normalize fills defaults and mirrors deprecated fields for compatibility.
func (c *Config) Normalize() {
	if len(c.TrustedNetworkPrefixes) == 0 && len(c.HomeNetworkPrefixes) > 0 {
		c.TrustedNetworkPrefixes = append([]string(nil), c.HomeNetworkPrefixes...)
	}
	if len(c.HomeNetworkPrefixes) == 0 && len(c.TrustedNetworkPrefixes) > 0 {
		c.HomeNetworkPrefixes = append([]string(nil), c.TrustedNetworkPrefixes...)
	}
	if c.AutoConnectAway {
		c.AutoConnectUntrusted = true
	}
	c.AutoConnectAway = c.AutoConnectUntrusted
}
