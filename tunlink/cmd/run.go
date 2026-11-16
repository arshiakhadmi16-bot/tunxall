package cmd

import (
	"context"
	"fmt"

	"github.com/musix/backhaul-rewrite/config"
	"github.com/musix/backhaul-rewrite/internal/client"
	"github.com/musix/backhaul-rewrite/internal/server"
	"github.com/musix/backhaul-rewrite/internal/utils"

	"github.com/BurntSushi/toml"
)

var logger = utils.NewLogger("info")

// Run starts the server or client described by the config and blocks until ctx is cancelled.
func Run(configPath string, ctx context.Context) {
	cfg, err := LoadConfig(configPath)
	if err != nil {
		logger.Fatalf("failed to load config: %v", err)
	}

	if cfg.Server.BindAddr != "" {
		srv := server.NewServer(&cfg.Server, ctx)
		go srv.Start()
		<-ctx.Done()
		srv.Stop()
		logger.Info("server shutting down")
	} else {
		clnt := client.NewClient(&cfg.Client, ctx)
		go clnt.Start()
		<-ctx.Done()
		clnt.Stop()
		logger.Info("client shutting down")
	}
}

// LoadConfig reads, defaults and validates a config file.
func LoadConfig(path string) (*config.Config, error) {
	var cfg config.Config
	if _, err := toml.DecodeFile(path, &cfg); err != nil {
		return nil, err
	}
	applyDefaults(&cfg)
	if cfg.Server.BindAddr == "" && len(cfg.Client.GetRemoteAddrs()) == 0 {
		return nil, fmt.Errorf("neither [server] bind_addr nor [client] remote_addr/remote_addrs is set")
	}
	if cfg.Server.BindAddr != "" && cfg.Server.Token == defaultToken ||
		cfg.Server.BindAddr == "" && cfg.Client.Token == defaultToken {
		logger.Warn("no token configured, using the insecure default token — set `token` on both sides")
	}
	return &cfg, nil
}
