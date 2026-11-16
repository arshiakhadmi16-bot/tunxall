package cmd

import "github.com/musix/backhaul-rewrite/config"

const defaultToken = "something_secure"

func applyDefaults(cfg *config.Config) {
	// Server defaults
	if cfg.Server.Transport == "" {
		cfg.Server.Transport = config.TCP
	}
	if cfg.Server.Keepalive == 0 {
		cfg.Server.Keepalive = 30 // TCP keepalive; detect a dead peer sooner
	}
	if cfg.Server.ChannelSize == 0 {
		cfg.Server.ChannelSize = 2048
	}
	if cfg.Server.Heartbeat == 0 {
		cfg.Server.Heartbeat = 20 // control-channel heartbeat (was 40)
	}
	if cfg.Server.MuxCon == 0 {
		cfg.Server.MuxCon = 8
	}
	if cfg.Server.MuxVersion == 0 {
		cfg.Server.MuxVersion = 1
	}
	if cfg.Server.MaxFrameSize == 0 {
		cfg.Server.MaxFrameSize = 32768
	}
	if cfg.Server.MaxReceiveBuffer == 0 {
		cfg.Server.MaxReceiveBuffer = 4 * 1024 * 1024
	}
	if cfg.Server.MaxStreamBuffer == 0 {
		cfg.Server.MaxStreamBuffer = 65536
	}
	if cfg.Server.LogLevel == "" {
		cfg.Server.LogLevel = "info"
	}
	if cfg.Server.Token == "" {
		cfg.Server.Token = defaultToken
	}

	// Client defaults
	if cfg.Client.Transport == "" {
		cfg.Client.Transport = config.TCP
	}
	if cfg.Client.ConnectionPool == 0 {
		cfg.Client.ConnectionPool = 8
	}
	if cfg.Client.RetryInterval == 0 {
		cfg.Client.RetryInterval = 2 // reconnect faster after a drop (was 3)
	}
	if cfg.Client.Keepalive == 0 {
		cfg.Client.Keepalive = 30 // TCP keepalive; detect a dead peer sooner
	}
	if cfg.Client.DialTimeout == 0 {
		cfg.Client.DialTimeout = 10
	}
	if cfg.Client.MuxVersion == 0 {
		cfg.Client.MuxVersion = 1
	}
	if cfg.Client.MaxFrameSize == 0 {
		cfg.Client.MaxFrameSize = 32768
	}
	if cfg.Client.MaxReceiveBuffer == 0 {
		cfg.Client.MaxReceiveBuffer = 4 * 1024 * 1024
	}
	if cfg.Client.MaxStreamBuffer == 0 {
		cfg.Client.MaxStreamBuffer = 65536
	}
	if cfg.Client.LogLevel == "" {
		cfg.Client.LogLevel = "info"
	}
	if cfg.Client.Token == "" {
		cfg.Client.Token = defaultToken
	}

	// Health check defaults
	if cfg.Client.HealthCheckInterval == 0 {
		cfg.Client.HealthCheckInterval = 15 // probe servers more often (was 30)
	}
	if cfg.Client.HealthCheckTimeout == 0 {
		cfg.Client.HealthCheckTimeout = 3
	}
	if cfg.Client.MinSuccessRate == 0 {
		cfg.Client.MinSuccessRate = 70
	}
	if cfg.Client.SwitchThresholdMs == 0 {
		cfg.Client.SwitchThresholdMs = 50
	}
}
