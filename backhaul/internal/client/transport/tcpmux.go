package transport

import (
	"context"
	"fmt"
	"net"
	"sync/atomic"
	"time"

	"github.com/musix/backhaul-rewrite/internal/handlers"
	"github.com/musix/backhaul-rewrite/internal/network"
	"github.com/musix/backhaul-rewrite/internal/utils"

	"github.com/sirupsen/logrus"
	"github.com/xtaci/smux"
)

type TcpMuxClientConfig struct {
	RemoteAddr       string
	Token            string
	KeepAlive        time.Duration
	RetryInterval    time.Duration
	DialTimeOut      time.Duration
	ConnPoolSize     int
	Nodelay          bool
	AggressivePool   bool
	MuxVersion       int
	MaxFrameSize     int
	MaxReceiveBuffer int
	MaxStreamBuffer  int
}

type TcpMuxClient struct {
	config     *TcpMuxClientConfig
	smuxConfig *smux.Config
	ctx        context.Context
	cancel     context.CancelFunc
	logger     *logrus.Logger
}

func NewMuxClient(parentCtx context.Context, config *TcpMuxClientConfig, logger *logrus.Logger) *TcpMuxClient {
	ctx, cancel := context.WithCancel(parentCtx)

	smuxCfg := smux.DefaultConfig()
	smuxCfg.KeepAliveInterval = 20 * time.Second
	smuxCfg.KeepAliveTimeout = 40 * time.Second
	if config.MuxVersion == 1 || config.MuxVersion == 2 {
		smuxCfg.Version = config.MuxVersion
	}
	if config.MaxFrameSize > 0 && config.MaxFrameSize <= 65535 {
		smuxCfg.MaxFrameSize = config.MaxFrameSize
	}
	if config.MaxReceiveBuffer > 0 {
		smuxCfg.MaxReceiveBuffer = config.MaxReceiveBuffer
	}
	if config.MaxStreamBuffer > 0 {
		smuxCfg.MaxStreamBuffer = config.MaxStreamBuffer
	}

	return &TcpMuxClient{
		config:     config,
		smuxConfig: smuxCfg,
		ctx:        ctx,
		cancel:     cancel,
		logger:     logger,
	}
}

func (c *TcpMuxClient) Start() {
	c.logger.Infof("TCPMux client starting, remote %s", c.config.RemoteAddr)
	if err := smux.VerifyConfig(c.smuxConfig); err != nil {
		c.logger.Fatalf("invalid mux config: %v", err)
	}
	go runSessions(c.ctx, c.logger, c.config.RetryInterval, c.dialControl, c.serve)
}

func (c *TcpMuxClient) Stop() {
	c.cancel()
}

func (c *TcpMuxClient) dialControl(ctx context.Context) (net.Conn, error) {
	conn, err := network.TcpDialer(ctx, c.config.RemoteAddr, "", c.config.DialTimeOut, c.config.KeepAlive, true, 3, 0, 0, 0)
	if err != nil {
		return nil, err
	}
	if !utils.ClientControlHandshake(conn, c.config.Token, utils.SG_Chan, helloTimeout) {
		conn.Close()
		return nil, fmt.Errorf("handshake with %s failed (wrong token, server busy with another client, or not a backhaul server)", c.config.RemoteAddr)
	}
	return conn, nil
}

func (c *TcpMuxClient) serve(sess *clientSession, ctrl net.Conn) {
	go c.poolMaintainer(sess)
	runControl(c.ctx, sess, ctrl, c.logger, func() {
		atomic.AddInt32(&sess.loadConnections, 1)
		go c.sessionDialer(sess)
	})
}

func (c *TcpMuxClient) poolMaintainer(sess *clientSession) {
	for i := 0; i < c.config.ConnPoolSize; i++ {
		go c.sessionDialer(sess)
	}

	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-sess.ctx.Done():
			return
		case <-ticker.C:
			// keep at least ConnPoolSize live sessions
			for i := int(atomic.LoadInt32(&sess.poolConnections)); i < c.config.ConnPoolSize; i++ {
				go c.sessionDialer(sess)
			}
		}
	}
}

func (c *TcpMuxClient) sessionDialer(sess *clientSession) {
	if sess.ctx.Err() != nil {
		return
	}
	conn, err := network.TcpDialer(sess.ctx, c.config.RemoteAddr, "", c.config.DialTimeOut, c.config.KeepAlive, c.config.Nodelay, 3, 0, 0, 0)
	if err != nil {
		c.logger.Debugf("mux session dial failed: %v", err)
		return
	}
	if err := utils.SendHello(conn, c.config.Token, utils.SG_TCP); err != nil {
		conn.Close()
		return
	}

	session, err := smux.Client(conn, c.smuxConfig)
	if err != nil {
		conn.Close()
		return
	}
	atomic.AddInt32(&sess.poolConnections, 1)
	defer atomic.AddInt32(&sess.poolConnections, -1)

	// The server drops sessions of a previous control session, so close ours too.
	stop := context.AfterFunc(sess.ctx, func() { session.Close() })
	defer stop()

	for {
		stream, err := session.AcceptStream()
		if err != nil {
			session.Close()
			return
		}
		go c.handleStream(stream)
	}
}

func (c *TcpMuxClient) handleStream(stream *smux.Stream) {
	_ = stream.SetReadDeadline(time.Now().Add(helloTimeout))
	remoteAddr, transport, err := utils.ReceiveBinaryTransportString(stream)
	_ = stream.SetReadDeadline(time.Time{})
	if err != nil || transport != utils.SG_TCP {
		stream.Close()
		return
	}

	_, resolved, err := network.ResolveRemoteAddr(remoteAddr)
	if err != nil {
		c.logger.Warnf("bad target address %q: %v", remoteAddr, err)
		stream.Close()
		return
	}

	localConn, err := network.TcpDialer(c.ctx, resolved, "", c.config.DialTimeOut, c.config.KeepAlive, true, 1, 0, 0, 0)
	if err != nil {
		c.logger.Errorf("local dial failed: %v", err)
		stream.Close()
		return
	}
	handlers.TCPConnectionHandler(c.ctx, false, stream, localConn, c.logger, 0, false)
}
