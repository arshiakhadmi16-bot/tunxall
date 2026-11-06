package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/musix/backhaul-rewrite/config"
	"github.com/musix/backhaul-rewrite/internal/client"
	clienttransport "github.com/musix/backhaul-rewrite/internal/client/transport"
	"github.com/musix/backhaul-rewrite/internal/grpcconn"
	"github.com/musix/backhaul-rewrite/internal/health"
	"github.com/musix/backhaul-rewrite/internal/server"
	"github.com/musix/backhaul-rewrite/internal/utils"
)

const testToken = "e2e-token"

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// echoServer plays the role of the real service sitting behind the client.
func echoServer(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	return l.Addr().(*net.TCPAddr).Port
}

// roundTrip connects to the server's public port and expects an echo through the tunnel.
func roundTrip(addr, msg string) error {
	c, err := net.DialTimeout("tcp", addr, 2*time.Second)
	if err != nil {
		return err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := fmt.Fprintf(c, "%s\n", msg); err != nil {
		return err
	}
	line, err := bufio.NewReader(c).ReadString('\n')
	if err != nil {
		return err
	}
	if line != msg+"\n" {
		return fmt.Errorf("got %q, want %q", line, msg)
	}
	return nil
}

func waitRoundTrip(t *testing.T, addr string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	var err error
	for time.Now().Before(deadline) {
		if err = roundTrip(addr, "hello"); err == nil {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatalf("tunnel never passed traffic: %v", err)
}

func startPair(t *testing.T, ctx context.Context, tr config.TransportType, bindPort, publicPort, echoPort int) {
	t.Helper()
	srvCfg := &config.ServerConfig{
		BindAddr: fmt.Sprintf("127.0.0.1:%d", bindPort), Transport: tr, Token: testToken,
		Ports:     []string{fmt.Sprintf("127.0.0.1:%d=%d", publicPort, echoPort)},
		Keepalive: 75, Heartbeat: 2, ChannelSize: 128, MuxCon: 4, LogLevel: "error",
	}
	go server.NewServer(srvCfg, ctx).Start()

	cliCfg := &config.ClientConfig{
		RemoteAddr: fmt.Sprintf("127.0.0.1:%d", bindPort), Transport: tr, Token: testToken,
		ConnectionPool: 2, RetryInterval: 1, Keepalive: 75, DialTimeout: 2, LogLevel: "error",
	}
	go client.NewClient(cliCfg, ctx).Start()
}

var allTransports = []config.TransportType{config.TCP, config.TCPMUX, config.WS, config.GRPC}

func TestTunnelTransports(t *testing.T) {
	for _, tr := range allTransports {
		t.Run(string(tr), func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			bindPort, publicPort, echoPort := freePort(t), freePort(t), echoServer(t)
			startPair(t, ctx, tr, bindPort, publicPort, echoPort)

			public := fmt.Sprintf("127.0.0.1:%d", publicPort)
			waitRoundTrip(t, public)

			// Many sequential and parallel connections must all get through.
			errs := make(chan error, 20)
			for i := 0; i < 20; i++ {
				go func(i int) { errs <- roundTrip(public, fmt.Sprintf("msg-%d", i)) }(i)
			}
			for i := 0; i < 20; i++ {
				if err := <-errs; err != nil {
					t.Errorf("parallel round trip: %v", err)
				}
			}
		})
	}
}

func TestWrongTokenRejected(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	bindPort := freePort(t)
	go server.NewServer(&config.ServerConfig{
		BindAddr: fmt.Sprintf("127.0.0.1:%d", bindPort), Transport: config.TCP, Token: testToken,
		Heartbeat: 2, ChannelSize: 16, LogLevel: "error",
	}, ctx).Start()
	time.Sleep(200 * time.Millisecond)

	conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", bindPort))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if utils.ClientControlHandshake(conn, "wrong", utils.SG_Chan, 2*time.Second) {
		t.Fatal("server accepted a wrong token")
	}
}

// A health probe must not steal the control channel and must report a healthy server.
func TestHealthProbe(t *testing.T) {
	for _, tr := range allTransports {
		t.Run(string(tr), func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			bindPort, publicPort, echoPort := freePort(t), freePort(t), echoServer(t)
			startPair(t, ctx, tr, bindPort, publicPort, echoPort)
			public := fmt.Sprintf("127.0.0.1:%d", publicPort)
			waitRoundTrip(t, public)

			var dial health.DialFunc
			switch tr {
			case config.WS:
				dial = func(ctx context.Context, addr string, timeout time.Duration) (net.Conn, error) {
					return clienttransport.DialWS(ctx, "ws", addr, "", timeout)
				}
			case config.GRPC:
				dial = func(ctx context.Context, addr string, timeout time.Duration) (net.Conn, error) {
					return grpcconn.DialOnce(ctx, addr, false, timeout)
				}
			}
			addr := fmt.Sprintf("127.0.0.1:%d", bindPort)
			chk := health.NewChecker([]string{addr, "127.0.0.1:1"}, testToken, 30, 2, 70, 50, dial, utils.NewLogger("error"))
			chkCtx, chkCancel := context.WithTimeout(ctx, 3*time.Second)
			done := make(chan struct{})
			go func() { chk.Start(chkCtx); close(done) }() // first check runs immediately
			time.Sleep(1 * time.Second)

			snap := chk.StatsSnapshot()
			if snap[addr]["success"].(int) < 1 {
				t.Fatalf("health probe failed against a healthy server: %v", snap[addr])
			}
			if snap["127.0.0.1:1"]["fail"].(int) < 1 {
				t.Fatalf("dead server not marked as failed: %v", snap["127.0.0.1:1"])
			}
			chkCancel()
			<-done

			// the tunnel must still work after the probe
			if err := roundTrip(public, "after-probe"); err != nil {
				t.Fatalf("tunnel broken after health probe: %v", err)
			}
		})
	}
}

// When the client goes away and comes back, the server must accept the new
// control channel without dying on "address already in use".
func TestClientReconnect(t *testing.T) {
	srvCtx, srvCancel := context.WithCancel(context.Background())
	defer srvCancel()
	bindPort, publicPort, echoPort := freePort(t), freePort(t), echoServer(t)
	go server.NewServer(&config.ServerConfig{
		BindAddr: fmt.Sprintf("127.0.0.1:%d", bindPort), Transport: config.TCP, Token: testToken,
		Ports:     []string{fmt.Sprintf("127.0.0.1:%d=%d", publicPort, echoPort)},
		Heartbeat: 1, ChannelSize: 64, LogLevel: "error",
	}, srvCtx).Start()

	cliCfg := &config.ClientConfig{
		RemoteAddr: fmt.Sprintf("127.0.0.1:%d", bindPort), Transport: config.TCP, Token: testToken,
		ConnectionPool: 2, RetryInterval: 1, Keepalive: 75, DialTimeout: 2, LogLevel: "error",
	}
	public := fmt.Sprintf("127.0.0.1:%d", publicPort)

	c1, cancel1 := context.WithCancel(context.Background())
	go client.NewClient(cliCfg, c1).Start()
	waitRoundTrip(t, public)
	cancel1()
	time.Sleep(1500 * time.Millisecond)

	c2, cancel2 := context.WithCancel(context.Background())
	defer cancel2()
	go client.NewClient(cliCfg, c2).Start()
	waitRoundTrip(t, public)
}

// writeSelfSignedCert creates a throwaway TLS certificate for the grpcs test.
func writeSelfSignedCert(t *testing.T) (certFile, keyFile string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "tunxall-test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	certFile, keyFile = filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	_ = os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600)
	_ = os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0o600)
	return certFile, keyFile
}

func TestGRPCSBulkTransfer(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	certFile, keyFile := writeSelfSignedCert(t)
	bindPort, publicPort, echoPort := freePort(t), freePort(t), echoServer(t)

	go server.NewServer(&config.ServerConfig{
		BindAddr: fmt.Sprintf("127.0.0.1:%d", bindPort), Transport: config.GRPCS, Token: testToken,
		Ports:       []string{fmt.Sprintf("127.0.0.1:%d=%d", publicPort, echoPort)},
		TLSCertFile: certFile, TLSKeyFile: keyFile,
		Heartbeat: 2, ChannelSize: 64, LogLevel: "error",
	}, ctx).Start()
	go client.NewClient(&config.ClientConfig{
		RemoteAddr: fmt.Sprintf("127.0.0.1:%d", bindPort), Transport: config.GRPCS, Token: testToken,
		ConnectionPool: 2, RetryInterval: 1, Keepalive: 75, DialTimeout: 2, LogLevel: "error",
	}, ctx).Start()

	public := fmt.Sprintf("127.0.0.1:%d", publicPort)
	waitRoundTrip(t, public)

	// 2 MiB through the tunnel and back must arrive intact.
	payload := make([]byte, 2<<20)
	_, _ = rand.Read(payload)
	c, err := net.Dial("tcp", public)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(20 * time.Second))
	go func() { _, _ = c.Write(payload) }()
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(c, got); err != nil {
		t.Fatalf("reading echoed payload: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("payload corrupted in transit")
	}
}
