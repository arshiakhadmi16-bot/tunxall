package grpcconn

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/peer"
)

func peerAddr(ctx context.Context) (string, bool) {
	p, ok := peer.FromContext(ctx)
	if !ok || p.Addr == nil {
		return "", false
	}
	return p.Addr.String(), true
}

// ServerOptions returns the gRPC server options used by the tunnel server.
func ServerOptions(tlsCfg *tls.Config) []grpc.ServerOption {
	opts := []grpc.ServerOption{
		grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
			MinTime:             10 * time.Second,
			PermitWithoutStream: true,
		}),
		grpc.KeepaliveParams(keepalive.ServerParameters{
			Time:    30 * time.Second,
			Timeout: 10 * time.Second,
		}),
		grpc.MaxRecvMsgSize(1 << 20),
		grpc.InitialWindowSize(1 << 20),
		grpc.InitialConnWindowSize(4 << 20),
	}
	if tlsCfg != nil {
		opts = append(opts, grpc.Creds(credentials.NewTLS(tlsCfg)))
	}
	return opts
}

// NewClient creates a (lazily connecting) client for addr. secure selects TLS
// ("grpcs"); certificates are not verified, the shared token authenticates the server.
// If edgeIP is set, the TCP connection goes to edgeIP while :authority/SNI stay addr.
func NewClient(addr, edgeIP string, secure bool, dialTimeout time.Duration) (*grpc.ClientConn, error) {
	creds := insecure.NewCredentials()
	if secure {
		host, _, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, fmt.Errorf("remote_addr %q must be host:port: %w", addr, err)
		}
		creds = credentials.NewTLS(&tls.Config{InsecureSkipVerify: true, ServerName: host, NextProtos: []string{"h2"}})
	}
	nd := &net.Dialer{Timeout: dialTimeout, KeepAlive: 15 * time.Second}
	target := addr
	if edgeIP != "" {
		_, port, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, fmt.Errorf("remote_addr %q must be host:port: %w", addr, err)
		}
		target = edgeIP
		if _, _, err := net.SplitHostPort(edgeIP); err != nil {
			target = net.JoinHostPort(edgeIP, port)
		}
	}
	return grpc.NewClient("passthrough:///"+addr,
		grpc.WithTransportCredentials(creds),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return nd.DialContext(ctx, "tcp", target)
		}),
		grpc.WithKeepaliveParams(keepalive.ClientParameters{
			Time:                20 * time.Second,
			Timeout:             10 * time.Second,
			PermitWithoutStream: true,
		}),
		grpc.WithInitialWindowSize(1<<20),
		grpc.WithInitialConnWindowSize(4<<20),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(1<<20)),
	)
}

// WaitReady connects cc and waits until it is usable or timeout expires.
func WaitReady(ctx context.Context, cc *grpc.ClientConn, timeout time.Duration) error {
	return waitReady(ctx, cc, timeout, false)
}

// waitReady with failFast gives up on the first failed connection attempt
// instead of waiting for gRPC's reconnect backoff.
func waitReady(ctx context.Context, cc *grpc.ClientConn, timeout time.Duration, failFast bool) error {
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	tctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cc.Connect()
	for s := cc.GetState(); s != connectivity.Ready; s = cc.GetState() {
		if s == connectivity.Shutdown {
			return fmt.Errorf("grpc client is closed")
		}
		if failFast && s == connectivity.TransientFailure {
			return fmt.Errorf("grpc connect to %s failed", cc.Target())
		}
		if !cc.WaitForStateChange(tctx, s) {
			return fmt.Errorf("grpc connect to %s: timed out (state %s)", cc.Target(), s)
		}
	}
	return nil
}

// DialOnce opens a dedicated client + stream; closing the Conn closes both.
// Used for health probes.
func DialOnce(ctx context.Context, addr string, secure bool, timeout time.Duration) (net.Conn, error) {
	cc, err := NewClient(addr, "", secure, timeout)
	if err != nil {
		return nil, err
	}
	if err := waitReady(ctx, cc, timeout, true); err != nil {
		cc.Close()
		return nil, err
	}
	conn, err := OpenStream(ctx, cc)
	if err != nil {
		cc.Close()
		return nil, err
	}
	inner := conn.onClose
	conn.onClose = func() { inner(); cc.Close() }
	return conn, nil
}
