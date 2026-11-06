package handlers

import (
	"context"
	"io"
	"net"
	"sync"

	"github.com/sirupsen/logrus"
)

// TCPConnectionHandler copies data bidirectionally between two connections.
// proxyProtocol is reserved for future HAProxy PROXY protocol support.
func TCPConnectionHandler(ctx context.Context, proxyProtocol bool, conn1, conn2 net.Conn, logger *logrus.Logger, port int, sniffer bool) {
	defer conn1.Close()
	defer conn2.Close()

	var wg sync.WaitGroup
	wg.Add(2)

	// conn1 -> conn2
	go func() {
		defer wg.Done()
		n, err := io.Copy(conn2, conn1)
		if err != nil && err != io.EOF {
			logger.Debugf("copy conn1->conn2 error (port %d): %v", port, err)
		}
		logger.Tracef("copied %d bytes conn1->conn2 (port %d)", n, port)
		// Force close the other side to unblock
		conn2.Close()
	}()

	// conn2 -> conn1
	go func() {
		defer wg.Done()
		n, err := io.Copy(conn1, conn2)
		if err != nil && err != io.EOF {
			logger.Debugf("copy conn2->conn1 error (port %d): %v", port, err)
		}
		logger.Tracef("copied %d bytes conn2->conn1 (port %d)", n, port)
		conn1.Close()
	}()

	// Wait for either side to finish or context cancel
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-ctx.Done():
		conn1.Close()
		conn2.Close()
	case <-done:
	}
}
