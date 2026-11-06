package transport

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/musix/backhaul-rewrite/internal/handlers"
	"github.com/musix/backhaul-rewrite/internal/network"
	"github.com/musix/backhaul-rewrite/internal/utils"

	"github.com/sirupsen/logrus"
)

const (
	helloTimeout     = 3 * time.Second
	localConnTimeout = 3 * time.Second // how long a user connection may wait for a tunnel
)

type LocalTCPConn struct {
	conn        net.Conn
	remoteAddr  string
	timeCreated time.Time
}

// controlServer holds the logic shared by every server transport: accepting one
// control channel at a time, heartbeats, asking the client for new tunnel
// connections and accepting user connections on the mapped ports.
//
// The tunnel and port listeners live for the whole transport lifetime; only the
// control session is replaced when the client reconnects, so a restart never has
// to re-bind a port.
type controlServer struct {
	ctx            context.Context
	token          string
	heartbeat      time.Duration
	logger         *logrus.Logger
	controlCh      chan net.Conn // unbuffered: a send succeeds only while no session is active
	reqNewConnChan chan struct{}
	localChannel   chan LocalTCPConn
}

func newControlServer(ctx context.Context, token string, heartbeat time.Duration, channelSize int, logger *logrus.Logger) controlServer {
	if heartbeat <= 0 {
		heartbeat = 40 * time.Second
	}
	if channelSize <= 0 {
		channelSize = 2048
	}
	return controlServer{
		ctx:            ctx,
		token:          token,
		heartbeat:      heartbeat,
		logger:         logger,
		controlCh:      make(chan net.Conn),
		reqNewConnChan: make(chan struct{}, channelSize),
		localChannel:   make(chan LocalTCPConn, channelSize),
	}
}

// offerControl hands a freshly authenticated control connection to runSessions.
// It fails if a control session is already active.
func (s *controlServer) offerControl(conn net.Conn) bool {
	select {
	case s.controlCh <- conn:
		return true
	default:
		return false
	}
}

// replyPing answers a health probe.
func (s *controlServer) replyPing(conn net.Conn) {
	_ = conn.SetWriteDeadline(time.Now().Add(helloTimeout))
	_ = utils.SendBinaryTransportString(conn, s.token, utils.SG_Ping)
	conn.Close()
}

// runSessions serves control sessions one after another until the transport stops.
// onNewSession runs before each session starts (used to drop stale tunnel conns).
func (s *controlServer) runSessions(onNewSession func()) {
	for {
		var conn net.Conn
		select {
		case <-s.ctx.Done():
			return
		case conn = <-s.controlCh:
		}
		if err := utils.SendBinaryTransportString(conn, s.token, utils.SG_Chan); err != nil {
			conn.Close()
			continue
		}
		s.logger.Info("control channel established")
		drain(s.reqNewConnChan)
		if onNewSession != nil {
			onNewSession()
		}
		s.runControl(conn)
		conn.Close()
		s.logger.Warn("control channel closed, waiting for the client to reconnect")
	}
}

func (s *controlServer) runControl(conn net.Conn) {
	ctx, cancel := context.WithCancel(s.ctx)
	defer cancel()

	msgChan := make(chan byte, 16)
	go func() {
		defer cancel()
		for {
			msg, err := utils.ReceiveBinaryByte(conn)
			if err != nil {
				if ctx.Err() == nil {
					s.logger.Errorf("control channel read error: %v", err)
				}
				return
			}
			select {
			case msgChan <- msg:
			case <-ctx.Done():
				return
			}
		}
	}()

	ticker := time.NewTicker(s.heartbeat)
	defer ticker.Stop()

	_ = utils.SendBinaryByte(conn, utils.SG_RTT)

	for {
		select {
		case <-ctx.Done():
			if s.ctx.Err() != nil { // whole transport is shutting down
				_ = utils.SendBinaryByte(conn, utils.SG_Closed)
			}
			return
		case <-s.reqNewConnChan:
			if err := utils.SendBinaryByte(conn, utils.SG_Chan); err != nil {
				return
			}
		case <-ticker.C:
			if err := utils.SendBinaryByte(conn, utils.SG_HB); err != nil {
				return
			}
		case msg := <-msgChan:
			if msg == utils.SG_Closed {
				s.logger.Warn("control channel closed by client")
				return
			}
		}
	}
}

// requestTunnel asks the client (non-blocking) to open one more tunnel connection.
func (s *controlServer) requestTunnel() {
	select {
	case s.reqNewConnChan <- struct{}{}:
	default:
	}
}

// startPortListeners opens a local listener for every port mapping.
// requestPerConn controls whether every accepted user connection asks the client for a new tunnel.
func (s *controlServer) startPortListeners(ports []string, nodelay, requestPerConn bool) {
	for _, m := range parsePortMappings(ports, s.logger) {
		go s.portListener(m.local, m.remote, nodelay, requestPerConn)
		time.Sleep(time.Millisecond)
	}
}

func (s *controlServer) portListener(localAddr, remoteAddr string, nodelay, requestPerConn bool) {
	listener, err := network.ListenTCP(localAddr)
	if err != nil {
		s.logger.Errorf("failed to listen on %s: %v", localAddr, err)
		return
	}
	stop := closeOnDone(s.ctx, listener)
	defer stop()
	s.logger.Infof("local listener started on %s -> %s", localAddr, remoteAddr)

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
			_ = tcpConn.SetNoDelay(nodelay)
		}
		select {
		case s.localChannel <- LocalTCPConn{conn: conn, remoteAddr: remoteAddr, timeCreated: time.Now()}:
			if requestPerConn {
				s.requestTunnel()
			}
		default:
			s.logger.Warn("local channel full, discarding connection")
			conn.Close()
		}
	}
}

// handleLoop pairs user connections with idle tunnel connections (tcp / ws).
func (s *controlServer) handleLoop(tunnelChannel chan net.Conn, proxyProtocol bool) {
	for {
		select {
		case <-s.ctx.Done():
			return
		case localConn := <-s.localChannel:
			wait := localConnTimeout - time.Since(localConn.timeCreated)
			if wait <= 0 {
				localConn.conn.Close()
				continue
			}
			timer := time.NewTimer(wait)
			select {
			case <-s.ctx.Done():
				timer.Stop()
				localConn.conn.Close()
				return
			case <-timer.C:
				s.logger.Warn("no tunnel connection available in time, dropping user connection")
				localConn.conn.Close()
			case tunnelConn := <-tunnelChannel:
				timer.Stop()
				if err := utils.SendBinaryTransportString(tunnelConn, localConn.remoteAddr, utils.SG_TCP); err != nil {
					s.logger.Debugf("failed to send remote addr: %v", err)
					tunnelConn.Close()
					localConn.conn.Close()
					continue
				}
				go handlers.TCPConnectionHandler(s.ctx, proxyProtocol, localConn.conn, tunnelConn, s.logger, 0, false)
			}
		}
	}
}

// closeOnDone closes c when ctx is cancelled; the returned func cancels that.
func closeOnDone(ctx context.Context, c interface{ Close() error }) func() bool {
	return context.AfterFunc(ctx, func() { c.Close() })
}

func drain[T any](ch chan T) {
	for {
		select {
		case <-ch:
		default:
			return
		}
	}
}

func drainConns(ch chan net.Conn) {
	for {
		select {
		case c := <-ch:
			c.Close()
		default:
			return
		}
	}
}

type portMapping struct{ local, remote string }

// parsePortMappings understands "443", "8080=80", "127.0.0.1:9000=9000",
// "10000-10010" and "10000-10010=443".
func parsePortMappings(ports []string, logger *logrus.Logger) []portMapping {
	var out []portMapping
	for _, mapping := range ports {
		parts := strings.Split(mapping, "=")
		if len(parts) > 2 {
			logger.Errorf("invalid port mapping: %s", mapping)
			continue
		}
		localPart := strings.TrimSpace(parts[0])
		remotePart := localPart
		if len(parts) == 2 {
			remotePart = strings.TrimSpace(parts[1])
		}
		if localPart == "" || remotePart == "" {
			logger.Errorf("invalid port mapping: %s", mapping)
			continue
		}

		if strings.Contains(localPart, "-") && !strings.Contains(localPart, ":") {
			r := strings.Split(localPart, "-")
			start, err1 := strconv.Atoi(strings.TrimSpace(r[0]))
			end, err2 := strconv.Atoi(strings.TrimSpace(r[len(r)-1]))
			if len(r) != 2 || err1 != nil || err2 != nil || start < 1 || end > 65535 || start > end {
				logger.Errorf("invalid port range: %s", localPart)
				continue
			}
			sameTarget := len(parts) == 1
			for p := start; p <= end; p++ {
				target := remotePart
				if sameTarget {
					target = strconv.Itoa(p) // "10000-10010" maps each port to itself
				}
				out = append(out, portMapping{local: fmt.Sprintf(":%d", p), remote: target})
			}
			continue
		}

		localAddr := localPart
		if !strings.Contains(localPart, ":") {
			localAddr = ":" + localPart
		}
		out = append(out, portMapping{local: localAddr, remote: remotePart})
	}
	return out
}
