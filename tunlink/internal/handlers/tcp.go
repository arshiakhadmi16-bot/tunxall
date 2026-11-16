package handlers

import (
	"context"
	"io"
	"net"
	"sync"
	"time"

	"github.com/musix/backhaul-rewrite/internal/utils"

	"github.com/sirupsen/logrus"
)

// TCPConnectionHandler copies data bidirectionally between a local connection
// (user or backend service) and a tunnel connection.
// If obfuscate is true, only the tunnelConn side is wrapped with random padding
// framing. Both ends of the tunnel must use the same setting.
func TCPConnectionHandler(ctx context.Context, proxyProtocol bool, localConn, tunnelConn net.Conn, logger *logrus.Logger, port int, sniffer bool, obfuscate bool) {
	if obfuscate {
		pc := utils.NewPaddedConn(tunnelConn, 384, 1100)
		pc.StartCoverTraffic(4 * time.Second)
		tunnelConn = pc
	}

	defer localConn.Close()
	defer tunnelConn.Close()

	var wg sync.WaitGroup
	wg.Add(2)

	copyFn := func(dst, src net.Conn, label string) {
		defer wg.Done()
		n, err := io.Copy(dst, src)
		if err != nil && err != io.EOF {
			logger.Debugf("copy %s error (port %d): %v", label, port, err)
		}
		logger.Tracef("copied %d bytes %s (port %d)", n, label, port)
		_ = dst.Close()
	}

	go copyFn(tunnelConn, localConn, "local->tunnel")
	go copyFn(localConn, tunnelConn, "tunnel->local")

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-ctx.Done():
		_ = localConn.Close()
		_ = tunnelConn.Close()
	case <-done:
	}
}
