package client

import (
	"context"
	"net"
	"sync"
	"time"

	"github.com/musix/backhaul-rewrite/config"
	"github.com/musix/backhaul-rewrite/internal/client/transport"
	"github.com/musix/backhaul-rewrite/internal/grpcconn"
	"github.com/musix/backhaul-rewrite/internal/health"
	"github.com/musix/backhaul-rewrite/internal/utils"

	"github.com/sirupsen/logrus"
)

type Client struct {
	config  *config.ClientConfig
	ctx     context.Context
	cancel  context.CancelFunc
	logger  *logrus.Logger
	checker *health.Checker

	// The active transport runs under its own context so that switching servers
	// stops only the transport, not the health checker or the client itself.
	mu              sync.Mutex
	transportCancel context.CancelFunc
}

func NewClient(cfg *config.ClientConfig, parentCtx context.Context) *Client {
	ctx, cancel := context.WithCancel(parentCtx)
	return &Client{
		config: cfg,
		ctx:    ctx,
		cancel: cancel,
		logger: utils.NewLogger(cfg.LogLevel),
	}
}

func (c *Client) Start() {
	addrs := c.config.GetRemoteAddrs()
	if len(addrs) == 0 {
		c.logger.Fatal("no remote address configured (remote_addr or remote_addrs)")
	}

	// Multi-server mode with health checking
	if len(addrs) > 1 {
		c.logger.Infof("multi-server mode enabled with %d servers: %v", len(addrs), addrs)
		c.checker = health.NewChecker(
			addrs,
			c.config.Token,
			c.config.HealthCheckInterval,
			c.config.HealthCheckTimeout,
			c.config.MinSuccessRate,
			c.config.SwitchThresholdMs,
			c.probeDialer(),
			c.logger,
		)

		// When preferred server changes, restart only the active transport
		c.checker.SetOnSwitch(func(oldAddr, newAddr string) {
			c.logger.Warnf("preferred server changed %s → %s, restarting tunnel...", oldAddr, newAddr)
			c.startTransport(newAddr)
		})

		// Start with the initially selected server
		current := c.checker.Current()
		c.logger.Infof("initial preferred server: %s", current)
		c.startTransport(current)

		go c.checker.Start(c.ctx)

		// Periodic stats logging
		go c.logStats()
	} else {
		// Single server mode (original behavior)
		c.logger.Infof("single-server mode: %s", addrs[0])
		c.startTransport(addrs[0])
	}

	<-c.ctx.Done()
	c.logger.Info("client stopped")
}

// startTransport stops the currently running transport (if any) and starts a new
// one towards remoteAddr.
func (c *Client) startTransport(remoteAddr string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ctx.Err() != nil {
		return
	}
	if c.transportCancel != nil {
		c.transportCancel()
	}
	ctx, cancel := context.WithCancel(c.ctx)
	c.transportCancel = cancel

	switch c.config.Transport {
	case config.TCP:
		cfg := &transport.TcpConfig{
			RemoteAddr:     remoteAddr,
			Token:          c.config.Token,
			KeepAlive:      time.Duration(c.config.Keepalive) * time.Second,
			RetryInterval:  time.Duration(c.config.RetryInterval) * time.Second,
			DialTimeOut:    time.Duration(c.config.DialTimeout) * time.Second,
			ConnPoolSize:   c.config.ConnectionPool,
			Nodelay:        c.config.Nodelay,
			AggressivePool: c.config.AggressivePool,
			MSS:            c.config.MSS,
			SO_RCVBUF:      c.config.SO_RCVBUF,
			SO_SNDBUF:      c.config.SO_SNDBUF,
		}
		cl := transport.NewTCPClient(ctx, cfg, c.logger)
		cl.Start()

	case config.TCPMUX:
		cfg := &transport.TcpMuxClientConfig{
			RemoteAddr:       remoteAddr,
			Token:            c.config.Token,
			KeepAlive:        time.Duration(c.config.Keepalive) * time.Second,
			RetryInterval:    time.Duration(c.config.RetryInterval) * time.Second,
			DialTimeOut:      time.Duration(c.config.DialTimeout) * time.Second,
			ConnPoolSize:     c.config.ConnectionPool,
			Nodelay:          c.config.Nodelay,
			AggressivePool:   c.config.AggressivePool,
			MuxVersion:       c.config.MuxVersion,
			MaxFrameSize:     c.config.MaxFrameSize,
			MaxReceiveBuffer: c.config.MaxReceiveBuffer,
			MaxStreamBuffer:  c.config.MaxStreamBuffer,
		}
		cl := transport.NewMuxClient(ctx, cfg, c.logger)
		cl.Start()

	case config.WS, config.WSS:
		cfg := &transport.WsClientConfig{
			RemoteAddr:     remoteAddr,
			Token:          c.config.Token,
			KeepAlive:      time.Duration(c.config.Keepalive) * time.Second,
			RetryInterval:  time.Duration(c.config.RetryInterval) * time.Second,
			DialTimeOut:    time.Duration(c.config.DialTimeout) * time.Second,
			ConnPoolSize:   c.config.ConnectionPool,
			Nodelay:        c.config.Nodelay,
			AggressivePool: c.config.AggressivePool,
			Mode:           string(c.config.Transport),
			EdgeIP:         c.config.EdgeIP,
		}
		cl := transport.NewWSClient(ctx, cfg, c.logger)
		cl.Start()

	case config.GRPC, config.GRPCS:
		cfg := &transport.GrpcClientConfig{
			RemoteAddr:    remoteAddr,
			Token:         c.config.Token,
			KeepAlive:     time.Duration(c.config.Keepalive) * time.Second,
			RetryInterval: time.Duration(c.config.RetryInterval) * time.Second,
			DialTimeOut:   time.Duration(c.config.DialTimeout) * time.Second,
			ConnPoolSize:  c.config.ConnectionPool,
			Mode:          string(c.config.Transport),
			EdgeIP:        c.config.EdgeIP,
		}
		cl := transport.NewGRPCClient(ctx, cfg, c.logger)
		cl.Start()

	default:
		c.logger.Fatalf("unsupported transport: %s", c.config.Transport)
	}
}

func (c *Client) logStats() {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case <-ticker.C:
			if c.checker == nil {
				continue
			}
			snap := c.checker.StatsSnapshot()
			c.logger.Info("=== Server Health Stats ===")
			for addr, s := range snap {
				mark := " "
				if s["is_current"].(bool) {
					mark = "→"
				}
				c.logger.Infof("%s %s | success=%.1f%%  avgRTT=%dms  score=%.1f  fails=%d",
					mark, addr,
					s["success_rate"].(float64),
					s["avg_rtt_ms"].(int64),
					s["score"].(float64),
					s["consecutive_fail"].(int),
				)
			}
		}
	}
}

// probeDialer returns how the health checker reaches a server for the configured transport.
func (c *Client) probeDialer() health.DialFunc {
	switch c.config.Transport {
	case config.WS, config.WSS:
		mode := string(c.config.Transport)
		return func(ctx context.Context, addr string, timeout time.Duration) (net.Conn, error) {
			return transport.DialWS(ctx, mode, addr, "", timeout)
		}
	case config.GRPC, config.GRPCS:
		secure := c.config.Transport == config.GRPCS
		return func(ctx context.Context, addr string, timeout time.Duration) (net.Conn, error) {
			return grpcconn.DialOnce(ctx, addr, secure, timeout)
		}
	default:
		return nil // plain TCP
	}
}

func (c *Client) Stop() {
	c.cancel()
}
