package transport

import (
	"context"
	"net"
	"sync"
	"time"

	"github.com/musix/backhaul-rewrite/internal/utils"

	"github.com/sirupsen/logrus"
)

const helloTimeout = 3 * time.Second

// controlIdleTimeout: reconnect if no byte (heartbeat/signal) arrives from the
// server within this window. Comfortably above the default 20s heartbeat so it
// never misfires, while still catching a black-holed link within ~2 minutes.
const controlIdleTimeout = 120 * time.Second

// clientSession is the state of one control-channel session. A new one is created
// every time the client (re)connects, so goroutines of an old session never touch
// the counters or context of the new one.
type clientSession struct {
	ctx             context.Context
	cancel          context.CancelFunc
	poolConnections int32
	loadConnections int32
	controlFlow     chan struct{}
}

func newClientSession(parent context.Context) *clientSession {
	ctx, cancel := context.WithCancel(parent)
	return &clientSession{ctx: ctx, cancel: cancel, controlFlow: make(chan struct{}, 100)}
}

// runSessions keeps a control channel up until ctx is cancelled: dial, run the
// session, and after it ends wait retry and start over.
func runSessions(ctx context.Context, logger *logrus.Logger, retry time.Duration,
	dial func(ctx context.Context) (net.Conn, error),
	serve func(sess *clientSession, ctrl net.Conn)) {
	if retry <= 0 {
		retry = 3 * time.Second
	}
	for ctx.Err() == nil {
		conn, err := dial(ctx)
		if err != nil {
			logger.Errorf("control channel connect failed: %v", err)
			sleepCtx(ctx, retry)
			continue
		}
		logger.Info("control channel established")
		sess := newClientSession(ctx)
		serve(sess, conn)
		sess.cancel()
		conn.Close()
		if ctx.Err() == nil {
			logger.Warn("control channel lost, reconnecting...")
			sleepCtx(ctx, retry)
		}
	}
}

// runControl reads signals from the server until the channel breaks or the
// session ends. onChan is called for every SG_Chan request.
func runControl(transportCtx context.Context, sess *clientSession, conn net.Conn, logger *logrus.Logger, onChan func()) {
	var writeMu sync.Mutex
	send := func(b byte) {
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		_ = utils.SendBinaryByte(conn, b)
		_ = conn.SetWriteDeadline(time.Time{})
	}
	stop := context.AfterFunc(sess.ctx, func() {
		if transportCtx.Err() != nil { // shutting down: tell the server politely
			send(utils.SG_Closed)
		}
		conn.Close()
	})
	defer stop()

	for {
		// The server sends a heartbeat every ~20s; if nothing arrives within
		// controlIdleTimeout the link is silently dead (black-holed), so drop it
		// and reconnect instead of waiting on TCP keepalive.
		_ = conn.SetReadDeadline(time.Now().Add(controlIdleTimeout))
		msg, err := utils.ReceiveBinaryByte(conn)
		if err != nil {
			if sess.ctx.Err() == nil {
				logger.Errorf("control channel error: %v", err)
			}
			return
		}
		switch msg {
		case utils.SG_Chan:
			onChan()
		case utils.SG_HB:
		case utils.SG_RTT:
			send(utils.SG_RTT)
		case utils.SG_Closed:
			logger.Warn("control channel closed by server")
			return
		}
	}
}

// awaitTarget waits for the server to send the target address on an idle tunnel
// connection; the connection is closed if the session ends first.
func awaitTarget(sess *clientSession, conn net.Conn) (string, byte, bool) {
	stop := context.AfterFunc(sess.ctx, func() { conn.Close() })
	addr, kind, err := utils.ReceiveBinaryTransportString(conn)
	if !stop() || err != nil { // session ended (conn closed) or read failed
		conn.Close()
		return "", 0, false
	}
	return addr, kind, true
}

func sleepCtx(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}
