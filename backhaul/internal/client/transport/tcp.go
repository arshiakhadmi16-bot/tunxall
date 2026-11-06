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
)

type TcpConfig struct {
	RemoteAddr     string
	Token          string
	KeepAlive      time.Duration
	RetryInterval  time.Duration
	DialTimeOut    time.Duration
	ConnPoolSize   int
	Nodelay        bool
	AggressivePool bool
	MSS            int
	SO_RCVBUF      int
	SO_SNDBUF      int
}

type TcpTransport struct {
	config *TcpConfig
	ctx    context.Context
	cancel context.CancelFunc
	logger *logrus.Logger
}

func NewTCPClient(parentCtx context.Context, config *TcpConfig, logger *logrus.Logger) *TcpTransport {
	ctx, cancel := context.WithCancel(parentCtx)
	return &TcpTransport{
		config: config,
		ctx:    ctx,
		cancel: cancel,
		logger: logger,
	}
}

func (c *TcpTransport) Start() {
	c.logger.Infof("TCP client starting, connecting to %s", c.config.RemoteAddr)
	go runSessions(c.ctx, c.logger, c.config.RetryInterval, c.dialControl, c.serve)
}

func (c *TcpTransport) Stop() {
	c.cancel()
}

func (c *TcpTransport) dialControl(ctx context.Context) (net.Conn, error) {
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

func (c *TcpTransport) serve(sess *clientSession, ctrl net.Conn) {
	go c.poolMaintainer(sess)
	runControl(c.ctx, sess, ctrl, c.logger, func() {
		atomic.AddInt32(&sess.loadConnections, 1)
		select {
		case <-sess.controlFlow:
			// pool decrease signal: skip this dial
		default:
			go c.tunnelDialer(sess)
		}
	})
}

func (c *TcpTransport) poolMaintainer(sess *clientSession) {
	for i := 0; i < c.config.ConnPoolSize; i++ {
		go c.tunnelDialer(sess)
	}

	a, b, x, y := 4, 5, 3, 4.0
	if c.config.AggressivePool {
		a, b, x, y = 1, 2, 0, 0.75
	}

	tickerPool := time.NewTicker(1 * time.Second)
	tickerLoad := time.NewTicker(10 * time.Second)
	defer tickerPool.Stop()
	defer tickerLoad.Stop()

	poolSum := 0
	newPoolSize := c.config.ConnPoolSize

	for {
		select {
		case <-sess.ctx.Done():
			return
		case <-tickerPool.C:
			poolSum += int(atomic.LoadInt32(&sess.poolConnections))
		case <-tickerLoad.C:
			load := (int(atomic.SwapInt32(&sess.loadConnections, 0)) + 9) / 10
			avgPool := (poolSum + 9) / 10
			poolSum = 0

			if (load + a) > avgPool*b {
				newPoolSize++
				go c.tunnelDialer(sess)
			} else if float64(load+x) < float64(avgPool)*y && newPoolSize > c.config.ConnPoolSize {
				newPoolSize--
				select {
				case sess.controlFlow <- struct{}{}:
				default:
				}
			}
		}
	}
}

func (c *TcpTransport) tunnelDialer(sess *clientSession) {
	if sess.ctx.Err() != nil {
		return
	}
	conn, err := network.TcpDialer(sess.ctx, c.config.RemoteAddr, "", c.config.DialTimeOut, c.config.KeepAlive, c.config.Nodelay, 3, c.config.SO_RCVBUF, c.config.SO_SNDBUF, c.config.MSS)
	if err != nil {
		c.logger.Debugf("tunnel dial failed: %v", err)
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

	port, resolved, err := network.ResolveRemoteAddr(remoteAddr)
	if err != nil {
		c.logger.Warnf("bad target address %q: %v", remoteAddr, err)
		conn.Close()
		return
	}

	switch transport {
	case utils.SG_TCP:
		c.localDialer(conn, resolved, port)
	default:
		c.logger.Warnf("unsupported transport type: %d", transport)
		conn.Close()
	}
}

func (c *TcpTransport) localDialer(tunnelConn net.Conn, addr string, port int) {
	localConn, err := network.TcpDialer(c.ctx, addr, "", c.config.DialTimeOut, c.config.KeepAlive, true, 1, 0, 0, 0)
	if err != nil {
		c.logger.Errorf("local dial to %s failed: %v", addr, err)
		tunnelConn.Close()
		return
	}
	c.logger.Debugf("connected to local %s", addr)
	handlers.TCPConnectionHandler(c.ctx, false, tunnelConn, localConn, c.logger, port, false)
}
