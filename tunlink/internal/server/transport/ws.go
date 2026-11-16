package transport

import (
	"context"
	"net"
	"net/http"
	"runtime"
	"strings"
	"time"

	"github.com/musix/backhaul-rewrite/internal/utils"
	"github.com/musix/backhaul-rewrite/internal/wsconn"

	"github.com/gorilla/websocket"
	"github.com/sirupsen/logrus"
)

type WsConfig struct {
	BindAddr    string
	Token       string
	Obfuscate   bool
	Ports       []string
	Nodelay     bool
	KeepAlive   time.Duration
	Heartbeat   time.Duration
	ChannelSize int
	Mode        string // "ws", "wss", or "https" (wss + decoy page)
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
	cs.obfuscate = config.Obfuscate
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

	if (s.config.Mode == "wss" || s.config.Mode == "https") && (s.config.TLSCertFile == "" || s.config.TLSKeyFile == "") {
		s.logger.Fatal("wss/https transport needs tls_cert and tls_key")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleHTTP)
	server := &http.Server{
		Addr:              s.config.BindAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	stop := closeOnDone(s.ctx, server)
	defer stop()

	go func() {
		var err error
		if s.config.Mode == "wss" || s.config.Mode == "https" {
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

// handleHTTP serves a decoy website for normal browsers, and upgrades
// WebSocket only when the client presents the tunnel token.
func (s *WsTransport) handleHTTP(w http.ResponseWriter, r *http.Request) {
	// Real tunnel clients always upgrade with Authorization or X-Token header
	// or path /tunnel (or /ws). Everything else gets a normal-looking page.
	isUpgrade := strings.EqualFold(r.Header.Get("Upgrade"), "websocket")
	tok := r.Header.Get("X-Token")
	if tok == "" {
		tok = strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	}
	pathOK := r.URL.Path == "/tunnel" || r.URL.Path == "/ws" || r.URL.Path == "/api/v1/stream"

	if isUpgrade && (tok == s.config.Token || pathOK) {
		s.handleWS(w, r)
		return
	}

	// Decoy: look like a normal small business / CDN edge page
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Server", "nginx")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(decoyHTML))
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

const decoyHTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Welcome</title>
<style>
body{font-family:system-ui,sans-serif;max-width:640px;margin:4rem auto;padding:0 1rem;color:#222}
h1{font-size:1.5rem} p{line-height:1.6;color:#444}
footer{margin-top:3rem;font-size:.85rem;color:#888}
</style>
</head>
<body>
<h1>Service Operational</h1>
<p>This host is running normally. If you are seeing this page, the edge is healthy.</p>
<p>For status updates please contact your administrator.</p>
<footer>&copy; 2026</footer>
</body>
</html>
`
