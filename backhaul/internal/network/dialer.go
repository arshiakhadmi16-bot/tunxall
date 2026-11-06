package network

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"
)

// TcpDialer dials a TCP connection with optional socket options.
func TcpDialer(ctx context.Context, addr, localAddr string, timeout, keepAlive time.Duration, nodelay bool, retries int, rcvBuf, sndBuf, mss int) (net.Conn, error) {
	var lastErr error
	for i := 0; i < retries; i++ {
		d := net.Dialer{
			Timeout:   timeout,
			KeepAlive: keepAlive,
		}
		if localAddr != "" {
			la, err := net.ResolveTCPAddr("tcp", localAddr)
			if err == nil {
				d.LocalAddr = la
			}
		}

		conn, err := d.DialContext(ctx, "tcp", addr)
		if err != nil {
			lastErr = err
			time.Sleep(200 * time.Millisecond)
			continue
		}

		tcpConn, ok := conn.(*net.TCPConn)
		if !ok {
			conn.Close()
			return nil, fmt.Errorf("not a TCP connection")
		}

		_ = tcpConn.SetNoDelay(nodelay)
		_ = tcpConn.SetKeepAlive(true)
		if keepAlive > 0 {
			_ = tcpConn.SetKeepAlivePeriod(keepAlive)
		}

		// Note: SO_RCVBUF / SO_SNDBUF / MSS require syscall and platform-specific code.
		// For portability we skip low-level setsockopt here. They can be added later.

		return tcpConn, nil
	}
	return nil, fmt.Errorf("failed after %d retries: %w", retries, lastErr)
}

// ListenTCP creates a TCP listener.
func ListenTCP(addr string) (net.Listener, error) {
	return net.Listen("tcp", addr)
}

// ResolveRemoteAddr parses remote address strings like "host:port" or just "port".
func ResolveRemoteAddr(addr string) (int, string, error) {
	addr = strings.TrimSpace(addr)
	if addr == "" {
		return 0, "", fmt.Errorf("empty address")
	}

	// Just a port number
	if !strings.Contains(addr, ":") && !strings.Contains(addr, ".") {
		port, err := strconv.Atoi(addr)
		if err != nil {
			return 0, "", err
		}
		return port, "127.0.0.1:" + addr, nil
	}

	host, portStr, err := net.SplitHostPort(addr)
	if err != nil {
		// maybe just "port"
		port, err2 := strconv.Atoi(addr)
		if err2 != nil {
			return 0, "", err
		}
		return port, "127.0.0.1:" + addr, nil
	}

	port, err := strconv.Atoi(portStr)
	if err != nil {
		return 0, "", err
	}
	if host == "" {
		host = "127.0.0.1"
	}
	return port, net.JoinHostPort(host, portStr), nil
}
