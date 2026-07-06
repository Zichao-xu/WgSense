// Package config 定义 WgSense 的运行配置。
package config

// Config 是 WgSense 守护的运行配置。
type Config struct {
	// HomeNetworkPrefixes 是家网段前缀(如 "10.10.1.")，命中则自动断开 WG。
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
		HomeNetworkPrefixes:        []string{"10.10.1."},
		IntervalSeconds:            10,
		AutoUpGraceSeconds:         20,
		HealthCheckTarget:          "https://www.google.com",
		HealthCheckIntervalSeconds: 30,
	}
}
