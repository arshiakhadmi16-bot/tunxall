package network

import (
	"bufio"
	"context"
	"encoding/base64"
	"fmt"
	"net"
	"net/url"
	"strings"
	"time"

	xproxy "golang.org/x/net/proxy"
)

// DialTCP dials addr (host:port). If proxyURL is empty, uses TcpDialer directly.
// Supported: socks5:// socks5h:// http:// (HTTPS CONNECT to proxy host)
//
//	socks5://127.0.0.1:1080
//	socks5://user:pass@10.0.0.1:1080
//	http://proxy.example.com:8080
//	http://user:pass@proxy:3128
func DialTCP(ctx context.Context, addr, proxyURL string, timeout, keepAlive time.Duration, nodelay bool) (net.Conn, error) {
	if strings.TrimSpace(proxyURL) == "" {
		return TcpDialer(ctx, addr, "", timeout, keepAlive, nodelay, 3, 0, 0, 0)
	}
	u, err := url.Parse(proxyURL)
	if err != nil {
		return nil, fmt.Errorf("invalid proxy url: %w", err)
	}
	switch strings.ToLower(u.Scheme) {
	case "socks5", "socks5h", "socks":
		return dialSOCKS5(ctx, u, addr, timeout)
	case "http", "https":
		return dialHTTPConnect(ctx, u, addr, timeout)
	default:
		return nil, fmt.Errorf("unsupported proxy scheme %q (use socks5:// or http://)", u.Scheme)
	}
}

func dialSOCKS5(ctx context.Context, u *url.URL, addr string, timeout time.Duration) (net.Conn, error) {
	var auth *xproxy.Auth
	if u.User != nil {
		pass, _ := u.User.Password()
		auth = &xproxy.Auth{User: u.User.Username(), Password: pass}
	}
	host := u.Host
	if !strings.Contains(host, ":") {
		host = net.JoinHostPort(host, "1080")
	}
	fwd := &net.Dialer{Timeout: timeout}
	// SOCKS5 builds on top of fwd to reach the proxy, then CONNECT to addr
	dialer, err := xproxy.SOCKS5("tcp", host, auth, fwd)
	if err != nil {
		return nil, fmt.Errorf("socks5 dialer: %w", err)
	}
	// Prefer context-aware dial when available
	type contextDialer interface {
		DialContext(ctx context.Context, network, address string) (net.Conn, error)
	}
	if cd, ok := dialer.(contextDialer); ok {
		return cd.DialContext(ctx, "tcp", addr)
	}
	return dialer.Dial("tcp", addr)
}

func dialHTTPConnect(ctx context.Context, u *url.URL, addr string, timeout time.Duration) (net.Conn, error) {
	proxyHost := u.Host
	if !strings.Contains(proxyHost, ":") {
		if strings.EqualFold(u.Scheme, "https") {
			proxyHost = net.JoinHostPort(proxyHost, "443")
		} else {
			proxyHost = net.JoinHostPort(proxyHost, "8080")
		}
	}
	d := &net.Dialer{Timeout: timeout}
	conn, err := d.DialContext(ctx, "tcp", proxyHost)
	if err != nil {
		return nil, fmt.Errorf("dial proxy %s: %w", proxyHost, err)
	}

	req := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\n", addr, addr)
	if u.User != nil {
		pass, _ := u.User.Password()
		token := base64.StdEncoding.EncodeToString([]byte(u.User.Username() + ":" + pass))
		req += "Proxy-Authorization: Basic " + token + "\r\n"
	}
	req += "User-Agent: tunlink/1.0\r\nProxy-Connection: Keep-Alive\r\n\r\n"

	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		conn.Close()
		return nil, err
	}
	if _, err := conn.Write([]byte(req)); err != nil {
		conn.Close()
		return nil, fmt.Errorf("proxy CONNECT write: %w", err)
	}

	br := bufio.NewReader(conn)
	status, err := br.ReadString('\n')
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("proxy CONNECT read: %w", err)
	}
	ok := strings.Contains(status, " 200 ") ||
		strings.HasPrefix(status, "HTTP/1.0 200") ||
		strings.HasPrefix(status, "HTTP/1.1 200")
	if !ok {
		conn.Close()
		return nil, fmt.Errorf("proxy CONNECT rejected: %s", strings.TrimSpace(status))
	}
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			conn.Close()
			return nil, err
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}
	_ = conn.SetDeadline(time.Time{})
	if br.Buffered() > 0 {
		return &bufferedConn{Conn: conn, r: br}, nil
	}
	return conn, nil
}

type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufferedConn) Read(b []byte) (int, error) {
	return c.r.Read(b)
}
