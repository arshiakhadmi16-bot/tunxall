package transport

import (
	"context"
	"fmt"
	"net"
	"sync/atomic"
	"time"

	"github.com/musix/backhaul-rewrite/internal/grpcconn"
	"github.com/musix/backhaul-rewrite/internal/handlers"
	"github.com/musix/backhaul-rewrite/internal/network"
	"github.com/musix/backhaul-rewrite/internal/utils"

	"github.com/sirupsen/logrus"
	"google.golang.org/grpc"
)

type GrpcClientConfig struct {
	RemoteAddr    string
	Token         string
	KeepAlive     time.Duration
	RetryInterval time.Duration
	DialTimeOut   time.Duration
	ConnPoolSize  int
	Mode          string // "grpc" or "grpcs"
	EdgeIP        string
}

// GrpcClient opens one HTTP/2 connection to the server and carries the control
// channel and every tunnel connection as separate gRPC streams on it.
type GrpcClient struct {
	config *GrpcClientConfig
	ctx    context.Context
	cancel context.CancelFunc
	logger *logrus.Logger
	cc     *grpc.ClientConn
}

func NewGRPCClient(parentCtx context.Context, config *GrpcClientConfig, logger *logrus.Logger) *GrpcClient {
	ctx, cancel := context.WithCancel(parentCtx)
	return &GrpcClient{
		config: config,
		ctx:    ctx,
		cancel: cancel,
		logger: logger,
	}
}

func (c *GrpcClient) Start() {
	c.logger.Infof("gRPC client (%s) starting, remote %s", c.config.Mode, c.config.RemoteAddr)
	cc, err := grpcconn.NewClient(c.config.RemoteAddr, c.config.EdgeIP, c.config.Mode == "grpcs", c.config.DialTimeOut)
	if err != nil {
		c.logger.Fatalf("grpc client: %v", err)
	}
	c.cc = cc
	context.AfterFunc(c.ctx, func() { cc.Close() })
	go runSessions(c.ctx, c.logger, c.config.RetryInterval, c.dialControl, c.serve)
}

func (c *GrpcClient) Stop() {
	c.cancel()
}

func (c *GrpcClient) openStream(ctx context.Context) (net.Conn, error) {
	if err := grpcconn.WaitReady(ctx, c.cc, c.config.DialTimeOut); err != nil {
		return nil, err
	}
	return grpcconn.OpenStream(ctx, c.cc)
}

func (c *GrpcClient) dialControl(ctx context.Context) (net.Conn, error) {
	conn, err := c.openStream(ctx)
	if err != nil {
		return nil, err
	}
	if !utils.ClientControlHandshake(conn, c.config.Token, utils.SG_Chan, helloTimeout) {
		conn.Close()
		return nil, fmt.Errorf("handshake with %s failed (wrong token, server busy with another client, or not a backhaul server)", c.config.RemoteAddr)
	}
	return conn, nil
}

func (c *GrpcClient) serve(sess *clientSession, ctrl net.Conn) {
	go c.poolMaintainer(sess)
	runControl(c.ctx, sess, ctrl, c.logger, func() {
		go c.tunnelDialer(sess)
	})
}

func (c *GrpcClient) poolMaintainer(sess *clientSession) {
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

func (c *GrpcClient) tunnelDialer(sess *clientSession) {
	if sess.ctx.Err() != nil {
		return
	}
	// Streams use the transport context so active transfers survive a control reconnect;
	// idle ones are closed by awaitTarget when the session ends.
	conn, err := c.openStream(c.ctx)
	if err != nil {
		c.logger.Debugf("grpc stream open failed: %v", err)
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
