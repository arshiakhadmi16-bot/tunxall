package transport

import (
	"context"
	"net"
	"net/http"
	"runtime"
	"time"

	"github.com/musix/backhaul-rewrite/internal/utils"
	"github.com/musix/backhaul-rewrite/internal/wsconn"

	"github.com/gorilla/websocket"
	"github.com/sirupsen/logrus"
)

type WsConfig struct {
	BindAddr    string
	Token       string
	Ports       []string
	Nodelay     bool
	KeepAlive   time.Duration
	Heartbeat   time.Duration
	ChannelSize int
	Mode        string // "ws" or "wss"
	TLSCertFile string
	TLSKeyFile  string
}

type WsTransport struct {
	controlServer
	config        *WsConfig
	cancel        context.CancelFunc
	tunnelChannel chan net.Conn
	upgrader      websocket.Upgrader
}

func NewWSServer(parentCtx context.Context, config *WsConfig, logger *logrus.Logger) *WsTransport {
	ctx, cancel := context.WithCancel(parentCtx)
	cs := newControlServer(ctx, config.Token, config.Heartbeat, config.ChannelSize, logger)
	return &WsTransport{
		controlServer: cs,
		config:        config,
		cancel:        cancel,
		tunnelChannel: make(chan net.Conn, cap(cs.localChannel)),
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool { return true },
		},
	}
}

func (s *WsTransport) Start() {
	s.logger.Infof("WebSocket server (%s) starting on %s", s.config.Mode, s.config.BindAddr)

	if s.config.Mode == "wss" && (s.config.TLSCertFile == "" || s.config.TLSKeyFile == "") {
		s.logger.Fatal("wss transport needs tls_cert and tls_key")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleWS)
	server := &http.Server{
		Addr:              s.config.BindAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	stop := closeOnDone(s.ctx, server)
	defer stop()

	go func() {
		var err error
		if s.config.Mode == "wss" {
			err = server.ListenAndServeTLS(s.config.TLSCertFile, s.config.TLSKeyFile)
		} else {
			err = server.ListenAndServe()
		}
		if err != nil && err != http.ErrServerClosed {
			s.logger.Fatalf("ws server error: %v", err)
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

func (s *WsTransport) Stop() {
	s.cancel()
}

func (s *WsTransport) handleWS(w http.ResponseWriter, r *http.Request) {
	wsConn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	conn := &wsconn.NetConn{Conn: wsConn}

	kind, ok := utils.ReadHello(conn, s.config.Token, helloTimeout)
	if !ok {
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
