package transport

import (
	"context"
	"errors"
	"net"
	"runtime"
	"time"

	"github.com/musix/backhaul-rewrite/internal/handlers"
	"github.com/musix/backhaul-rewrite/internal/network"
	"github.com/musix/backhaul-rewrite/internal/utils"

	"github.com/sirupsen/logrus"
	"github.com/xtaci/smux"
)

type TcpMuxConfig struct {
	BindAddr         string
	Token            string
	Ports            []string
	Nodelay          bool
	KeepAlive        time.Duration
	Heartbeat        time.Duration
	ChannelSize      int
	MuxCon           int
	MuxVersion       int
	MaxFrameSize     int
	MaxReceiveBuffer int
	MaxStreamBuffer  int
	ProxyProtocol    bool
}

type TcpMuxTransport struct {
	controlServer
	config        *TcpMuxConfig
	smuxConfig    *smux.Config
	cancel        context.CancelFunc
	tunnelChannel chan *smux.Session // pool of live sessions, round-robin
}

func NewTcpMuxServer(parentCtx context.Context, config *TcpMuxConfig, logger *logrus.Logger) *TcpMuxTransport {
	ctx, cancel := context.WithCancel(parentCtx)
	if config.MuxCon <= 0 {
		config.MuxCon = 8
	}
	cs := newControlServer(ctx, config.Token, config.Heartbeat, config.ChannelSize, logger)
	return &TcpMuxTransport{
		controlServer: cs,
		config:        config,
		smuxConfig:    newSmuxConfig(config.MuxVersion, config.MaxFrameSize, config.MaxReceiveBuffer, config.MaxStreamBuffer),
		cancel:        cancel,
		tunnelChannel: make(chan *smux.Session, cap(cs.localChannel)),
	}
}

func newSmuxConfig(version, frameSize, recvBuf, streamBuf int) *smux.Config {
	cfg := smux.DefaultConfig()
	cfg.KeepAliveInterval = 20 * time.Second
	cfg.KeepAliveTimeout = 40 * time.Second
	if version == 1 || version == 2 {
		cfg.Version = version
	}
	if frameSize > 0 && frameSize <= 65535 {
		cfg.MaxFrameSize = frameSize
	}
	if recvBuf > 0 {
		cfg.MaxReceiveBuffer = recvBuf
	}
	if streamBuf > 0 {
		cfg.MaxStreamBuffer = streamBuf
	}
	return cfg
}

func (s *TcpMuxTransport) Start() {
	s.logger.Infof("TCPMux server starting on %s", s.config.BindAddr)

	if err := smux.VerifyConfig(s.smuxConfig); err != nil {
		s.logger.Fatalf("invalid mux config: %v", err)
	}

	listener, err := network.ListenTCP(s.config.BindAddr)
	if err != nil {
		s.logger.Fatalf("failed to listen on %s: %v", s.config.BindAddr, err)
	}
	stop := closeOnDone(s.ctx, listener)
	defer stop()
	go s.acceptLoop(listener)

	// Sessions are long-lived and carry many streams: don't ask for a new one per user connection.
	s.startPortListeners(s.config.Ports, s.config.Nodelay, false)

	numCPU := runtime.NumCPU()
	if numCPU > 4 {
		numCPU = 4
	}
	for i := 0; i < numCPU; i++ {
		go s.muxHandleLoop()
	}

	s.runSessions(s.closeSessions)
}

func (s *TcpMuxTransport) Stop() {
	s.cancel()
}

func (s *TcpMuxTransport) closeSessions() {
	for {
		select {
		case sess := <-s.tunnelChannel:
			sess.Close()
		default:
			return
		}
	}
}

func (s *TcpMuxTransport) acceptLoop(listener net.Listener) {
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

func (s *TcpMuxTransport) handleIncoming(conn net.Conn) {
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
		session, err := smux.Server(conn, s.smuxConfig)
		if err != nil {
			conn.Close()
			return
		}
		select {
		case s.tunnelChannel <- session:
		default:
			session.Close()
		}
	case utils.SG_Ping:
		s.replyPing(conn)
	default:
		conn.Close()
	}
}

// nextSession returns a live session, waiting at most until deadline.
func (s *TcpMuxTransport) nextSession(deadline time.Time) *smux.Session {
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return nil
		case <-timer.C:
			return nil
		case sess := <-s.tunnelChannel:
			if sess.IsClosed() {
				s.requestTunnel()
				continue
			}
			return sess
		}
	}
}

func (s *TcpMuxTransport) muxHandleLoop() {
	for {
		select {
		case <-s.ctx.Done():
			return
		case localConn := <-s.localChannel:
			session := s.nextSession(localConn.timeCreated.Add(localConnTimeout))
			if session == nil {
				s.logger.Warn("no mux session available in time, dropping user connection")
				localConn.conn.Close()
				s.requestTunnel()
				continue
			}

			stream, err := session.OpenStream()
			if err != nil {
				session.Close()
				localConn.conn.Close()
				s.requestTunnel()
				continue
			}

			// Return the session to the pool; ask for another one once it is saturated.
			if session.NumStreams() >= s.config.MuxCon {
				s.requestTunnel()
			}
			select {
			case s.tunnelChannel <- session:
			default:
			}

			if err := utils.SendBinaryTransportString(stream, localConn.remoteAddr, utils.SG_TCP); err != nil {
				stream.Close()
				localConn.conn.Close()
				continue
			}
			go handlers.TCPConnectionHandler(s.ctx, s.config.ProxyProtocol, localConn.conn, stream, s.logger, 0, false)
		}
	}
}
