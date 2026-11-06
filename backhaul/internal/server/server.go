package server

import (
	"context"
	"time"

	"github.com/musix/backhaul-rewrite/config"
	"github.com/musix/backhaul-rewrite/internal/server/transport"
	"github.com/musix/backhaul-rewrite/internal/utils"

	"github.com/sirupsen/logrus"
)

type Server struct {
	config *config.ServerConfig
	ctx    context.Context
	cancel context.CancelFunc
	logger *logrus.Logger
}

func NewServer(cfg *config.ServerConfig, parentCtx context.Context) *Server {
	ctx, cancel := context.WithCancel(parentCtx)
	return &Server{
		config: cfg,
		ctx:    ctx,
		cancel: cancel,
		logger: utils.NewLogger(cfg.LogLevel),
	}
}

func (s *Server) Start() {
	switch s.config.Transport {
	case config.TCP:
		cfg := &transport.TcpConfig{
			BindAddr:      s.config.BindAddr,
			Token:         s.config.Token,
			Ports:         s.config.Ports,
			Nodelay:       s.config.Nodelay,
			KeepAlive:     time.Duration(s.config.Keepalive) * time.Second,
			Heartbeat:     time.Duration(s.config.Heartbeat) * time.Second,
			ChannelSize:   s.config.ChannelSize,
			AcceptUDP:     s.config.AcceptUDP,
			MSS:           s.config.MSS,
			SO_RCVBUF:     s.config.SO_RCVBUF,
			SO_SNDBUF:     s.config.SO_SNDBUF,
			ProxyProtocol: s.config.ProxyProtocol,
		}
		srv := transport.NewTCPServer(s.ctx, cfg, s.logger)
		go srv.Start()

	case config.TCPMUX:
		cfg := &transport.TcpMuxConfig{
			BindAddr:         s.config.BindAddr,
			Token:            s.config.Token,
			Ports:            s.config.Ports,
			Nodelay:          s.config.Nodelay,
			KeepAlive:        time.Duration(s.config.Keepalive) * time.Second,
			Heartbeat:        time.Duration(s.config.Heartbeat) * time.Second,
			ChannelSize:      s.config.ChannelSize,
			MuxCon:           s.config.MuxCon,
			MuxVersion:       s.config.MuxVersion,
			MaxFrameSize:     s.config.MaxFrameSize,
			MaxReceiveBuffer: s.config.MaxReceiveBuffer,
			MaxStreamBuffer:  s.config.MaxStreamBuffer,
			ProxyProtocol:    s.config.ProxyProtocol,
		}
		srv := transport.NewTcpMuxServer(s.ctx, cfg, s.logger)
		go srv.Start()

	case config.WS, config.WSS:
		cfg := &transport.WsConfig{
			BindAddr:    s.config.BindAddr,
			Token:       s.config.Token,
			Ports:       s.config.Ports,
			Nodelay:     s.config.Nodelay,
			KeepAlive:   time.Duration(s.config.Keepalive) * time.Second,
			Heartbeat:   time.Duration(s.config.Heartbeat) * time.Second,
			ChannelSize: s.config.ChannelSize,
			Mode:        string(s.config.Transport),
			TLSCertFile: s.config.TLSCertFile,
			TLSKeyFile:  s.config.TLSKeyFile,
		}
		srv := transport.NewWSServer(s.ctx, cfg, s.logger)
		go srv.Start()

	case config.GRPC, config.GRPCS:
		cfg := &transport.GrpcConfig{
			BindAddr:    s.config.BindAddr,
			Token:       s.config.Token,
			Ports:       s.config.Ports,
			Nodelay:     s.config.Nodelay,
			KeepAlive:   time.Duration(s.config.Keepalive) * time.Second,
			Heartbeat:   time.Duration(s.config.Heartbeat) * time.Second,
			ChannelSize: s.config.ChannelSize,
			Mode:        string(s.config.Transport),
			TLSCertFile: s.config.TLSCertFile,
			TLSKeyFile:  s.config.TLSKeyFile,
		}
		srv := transport.NewGRPCServer(s.ctx, cfg, s.logger)
		go srv.Start()

	default:
		s.logger.Fatalf("unsupported transport: %s", s.config.Transport)
	}

	<-s.ctx.Done()
	s.logger.Info("server stopped")
}

func (s *Server) Stop() {
	s.cancel()
}
