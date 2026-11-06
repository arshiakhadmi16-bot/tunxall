package transport

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"sync/atomic"
	"time"

	"github.com/musix/backhaul-rewrite/internal/handlers"
	"github.com/musix/backhaul-rewrite/internal/network"
	"github.com/musix/backhaul-rewrite/internal/utils"
	"github.com/musix/backhaul-rewrite/internal/wsconn"

	"github.com/gorilla/websocket"
	"github.com/sirupsen/logrus"
)

type WsClientConfig struct {
	RemoteAddr     string
	Token          string
	KeepAlive      time.Duration
	RetryInterval  time.Duration
	DialTimeOut    time.Duration
	ConnPoolSize   int
	Nodelay        bool
	AggressivePool bool
	Mode           string // "ws" or "wss"
	EdgeIP         string
}

type WsClient struct {
	config *WsClientConfig
	ctx    context.Context
	cancel context.CancelFunc
	logger *logrus.Logger
}

func NewWSClient(parentCtx context.Context, config *WsClientConfig, logger *logrus.Logger) *WsClient {
	ctx, cancel := context.WithCancel(parentCtx)
	return &WsClient{
		config: config,
		ctx:    ctx,
		cancel: cancel,
		logger: logger,
	}
}

func (c *WsClient) Start() {
	c.logger.Infof("WS client (%s) starting, remote %s", c.config.Mode, c.config.RemoteAddr)
	go runSessions(c.ctx, c.logger, c.config.RetryInterval, c.dialControl, c.serve)
}

func (c *WsClient) Stop() {
	c.cancel()
}

// DialWS opens a websocket to remoteAddr ("host:port"). If edgeIP is set, the TCP
// connection goes to edgeIP (e.g. a CDN edge) while Host/SNI stay remoteAddr.
func DialWS(ctx context.Context, mode, remoteAddr, edgeIP string, timeout time.Duration) (net.Conn, error) {
	scheme := "ws"
	if mode == "wss" {
		scheme = "wss"
	}
	u := url.URL{Scheme: scheme, Host: remoteAddr, Path: "/"}

	nd := &net.Dialer{Timeout: timeout, KeepAlive: 15 * time.Second}
	dialer := websocket.Dialer{
		HandshakeTimeout: timeout,
		// Self-signed certificates are the norm for this tool; the token authenticates the server.
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		NetDialContext:  nd.DialContext,
	}
	if edgeIP != "" {
		_, port, err := net.SplitHostPort(remoteAddr)
		if err != nil {
			return nil, fmt.Errorf("remote_addr %q must be host:port: %w", remoteAddr, err)
		}
		target := edgeIP
		if _, _, err := net.SplitHostPort(edgeIP); err != nil {
			target = net.JoinHostPort(edgeIP, port)
		}
		dialer.NetDialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
			return nd.DialContext(ctx, network, target)
		}
	}

	wsConn, _, err := dialer.DialContext(ctx, u.String(), http.Header{})
	if err != nil {
		return nil, err
	}
	return &wsconn.NetConn{Conn: wsConn}, nil
}

func (c *WsClient) dialWS(ctx context.Context) (net.Conn, error) {
	return DialWS(ctx, c.config.Mode, c.config.RemoteAddr, c.config.EdgeIP, c.config.DialTimeOut)
}

func (c *WsClient) dialControl(ctx context.Context) (net.Conn, error) {
	conn, err := c.dialWS(ctx)
	if err != nil {
		return nil, err
	}
	if !utils.ClientControlHandshake(conn, c.config.Token, utils.SG_Chan, helloTimeout) {
		conn.Close()
		return nil, fmt.Errorf("handshake with %s failed (wrong token, server busy with another client, or not a backhaul server)", c.config.RemoteAddr)
	}
	return conn, nil
}

func (c *WsClient) serve(sess *clientSession, ctrl net.Conn) {
	go c.poolMaintainer(sess)
	runControl(c.ctx, sess, ctrl, c.logger, func() {
		go c.tunnelDialer(sess)
	})
}

func (c *WsClient) poolMaintainer(sess *clientSession) {
	for i := 0; i < c.config.ConnPoolSize; i++ {
		go c.tunnelDialer(sess)
	}
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-sess.ctx.Done():
			return
		case <-ticker.C:
			if atomic.LoadInt32(&sess.poolConnections) < int32(c.config.ConnPoolSize) {
				go c.tunnelDialer(sess)
			}
		}
	}
}

func (c *WsClient) tunnelDialer(sess *clientSession) {
	if sess.ctx.Err() != nil {
		return
	}
	conn, err := c.dialWS(sess.ctx)
	if err != nil {
		c.logger.Debugf("ws tunnel dial failed: %v", err)
		return
	}
	if err := utils.SendHello(conn, c.config.Token, utils.SG_TCP); err != nil {
		conn.Close()
		return
	}

	atomic.AddInt32(&sess.poolConnections, 1)
	remoteAddr, transport, ok := awaitTarget(sess, conn)
	atomic.AddInt32(&sess.poolConnections, -1)
	if !ok {
		return
	}
	if transport != utils.SG_TCP {
		conn.Close()
		return
	}
	_, resolved, err := network.ResolveRemoteAddr(remoteAddr)
	if err != nil {
		c.logger.Warnf("bad target address %q: %v", remoteAddr, err)
		conn.Close()
		return
	}
	localConn, err := network.TcpDialer(c.ctx, resolved, "", c.config.DialTimeOut, c.config.KeepAlive, true, 1, 0, 0, 0)
	if err != nil {
		c.logger.Errorf("local dial to %s failed: %v", resolved, err)
		conn.Close()
		return
	}
	handlers.TCPConnectionHandler(c.ctx, false, conn, localConn, c.logger, 0, false)
}
