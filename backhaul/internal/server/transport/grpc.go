package transport

import (
	"context"
	"crypto/tls"
	"net"
	"runtime"
	"time"

	"github.com/musix/backhaul-rewrite/internal/grpcconn"
	"github.com/musix/backhaul-rewrite/internal/network"
	"github.com/musix/backhaul-rewrite/internal/utils"

	"github.com/sirupsen/logrus"
	"google.golang.org/grpc"
)

type GrpcConfig struct {
	BindAddr    string
	Token       string
	Ports       []string
	Nodelay     bool
	KeepAlive   time.Duration
	Heartbeat   time.Duration
	ChannelSize int
	Mode        string // "grpc" (plaintext h2c) or "grpcs" (TLS)
	TLSCertFile string
	TLSKeyFile  string
}

// GrpcTransport tunnels over gRPC: each bidirectional stream is one tunnel connection.
type GrpcTransport struct {
	controlServer
	config        *GrpcConfig
	cancel        context.CancelFunc
	tunnelChannel chan net.Conn
}

func NewGRPCServer(parentCtx context.Context, config *GrpcConfig, logger *logrus.Logger) *GrpcTransport {
	ctx, cancel := context.WithCancel(parentCtx)
	cs := newControlServer(ctx, config.Token, config.Heartbeat, config.ChannelSize, logger)
	return &GrpcTransport{
		controlServer: cs,
		config:        config,
		cancel:        cancel,
		tunnelChannel: make(chan net.Conn, cap(cs.localChannel)),
	}
}

func (s *GrpcTransport) Start() {
	s.logger.Infof("gRPC server (%s) starting on %s", s.config.Mode, s.config.BindAddr)

	var tlsCfg *tls.Config
	if s.config.Mode == "grpcs" {
		if s.config.TLSCertFile == "" || s.config.TLSKeyFile == "" {
			s.logger.Fatal("grpcs transport needs tls_cert and tls_key")
		}
		cert, err := tls.LoadX509KeyPair(s.config.TLSCertFile, s.config.TLSKeyFile)
		if err != nil {
			s.logger.Fatalf("failed to load TLS certificate: %v", err)
		}
		tlsCfg = &tls.Config{Certificates: []tls.Certificate{cert}, NextProtos: []string{"h2"}, MinVersion: tls.VersionTLS12}
	}

	listener, err := network.ListenTCP(s.config.BindAddr)
	if err != nil {
		s.logger.Fatalf("failed to listen on %s: %v", s.config.BindAddr, err)
	}

	server := grpc.NewServer(grpcconn.ServerOptions(tlsCfg)...)
	grpcconn.RegisterServer(server, listener.Addr().String(), s.handleStream)
	stop := context.AfterFunc(s.ctx, server.Stop) // also closes the listener
	defer stop()

	go func() {
		if err := server.Serve(listener); err != nil && s.ctx.Err() == nil {
			s.logger.Fatalf("grpc server error: %v", err)
		}
	}()

	s.startPortListeners(s.config.Ports, s.config.Nodelay, true)

	numCPU := runtime.NumCPU()
	if numCPU > 4 {
		numCPU = 4
	}
	for i := 0; i < numCPU; i++ {
		go s.handleLoop(s.tunnelChannel, false)
	}

	s.runSessions(func() { drainConns(s.tunnelChannel) })
}

func (s *GrpcTransport) Stop() {
	s.cancel()
}

func (s *GrpcTransport) handleStream(conn *grpcconn.Conn) {
	kind, ok := utils.ReadHello(conn, s.config.Token, helloTimeout)
	if !ok {
		s.logger.Debugf("rejected grpc stream from %s (bad handshake/token)", conn.RemoteAddr())
		conn.Close()
		return
	}
	switch kind {
	case utils.SG_Chan:
		if !s.offerControl(conn) {
			s.logger.Warn("control channel already active, rejecting a second one")
			conn.Close()
		}
	case utils.SG_TCP:
		select {
		case s.tunnelChannel <- conn:
		default:
			conn.Close()
		}
	case utils.SG_Ping:
		s.replyPing(conn)
	default:
		conn.Close()
	}
}
