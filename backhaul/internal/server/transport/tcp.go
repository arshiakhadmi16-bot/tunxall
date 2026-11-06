package transport

import (
	"context"
	"errors"
	"net"
	"runtime"
	"time"

	"github.com/musix/backhaul-rewrite/internal/network"
	"github.com/musix/backhaul-rewrite/internal/utils"

	"github.com/sirupsen/logrus"
)

type TcpConfig struct {
	BindAddr      string
	Token         string
	Ports         []string
	Nodelay       bool
	KeepAlive     time.Duration
	Heartbeat     time.Duration
	ChannelSize   int
	AcceptUDP     bool
	MSS           int
	SO_RCVBUF     int
	SO_SNDBUF     int
	ProxyProtocol bool
	LogLevel      string
}

type TcpTransport struct {
	controlServer
	config        *TcpConfig
	cancel        context.CancelFunc
	tunnelChannel chan net.Conn
}

func NewTCPServer(parentCtx context.Context, config *TcpConfig, logger *logrus.Logger) *TcpTransport {
	ctx, cancel := context.WithCancel(parentCtx)
	cs := newControlServer(ctx, config.Token, config.Heartbeat, config.ChannelSize, logger)
	return &TcpTransport{
		controlServer: cs,
		config:        config,
		cancel:        cancel,
		tunnelChannel: make(chan net.Conn, cap(cs.localChannel)),
	}
}

func (s *TcpTransport) Start() {
	s.logger.Infof("TCP server starting on %s", s.config.BindAddr)

	listener, err := network.ListenTCP(s.config.BindAddr)
	if err != nil {
		s.logger.Fatalf("failed to listen on %s: %v", s.config.BindAddr, err)
	}
	stop := closeOnDone(s.ctx, listener)
	defer stop()
	s.logger.Infof("tunnel listener started on %s", listener.Addr().String())
	go s.acceptLoop(listener)

	s.startPortListeners(s.config.Ports, s.config.Nodelay, true)

	numCPU := runtime.NumCPU()
	if numCPU > 4 {
		numCPU = 4
	}
	for i := 0; i < numCPU; i++ {
		go s.handleLoop(s.tunnelChannel, s.config.ProxyProtocol)
	}

	// Tunnel connections from a previous client session are useless: drop them.
	s.runSessions(func() { drainConns(s.tunnelChannel) })
}

func (s *TcpTransport) Stop() {
	s.cancel()
}

func (s *TcpTransport) acceptLoop(listener net.Listener) {
	for {
		conn, err := listener.Accept()
		if err != nil {
			if s.ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(50 * time.Millisecond)
			continue
		}
		if tcpConn, ok := conn.(*net.TCPConn); ok {
			_ = tcpConn.SetNoDelay(s.config.Nodelay)
			_ = tcpConn.SetKeepAlive(true)
			if s.config.KeepAlive > 0 {
				_ = tcpConn.SetKeepAlivePeriod(s.config.KeepAlive)
			}
		}
		go s.handleIncoming(conn)
	}
}

// handleIncoming authenticates a new connection and routes it by kind.
func (s *TcpTransport) handleIncoming(conn net.Conn) {
	kind, ok := utils.ReadHello(conn, s.config.Token, helloTimeout)
	if !ok {
		s.logger.Debugf("rejected connection from %s (bad handshake/token)", conn.RemoteAddr())
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
			s.logger.Warn("tunnel channel full, discarding connection")
			conn.Close()
		}
	case utils.SG_Ping:
		s.replyPing(conn)
	default:
		conn.Close()
	}
}
