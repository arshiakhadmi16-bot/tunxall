package utils

import (
	"crypto/subtle"
	"net"
	"time"
)

// Handshake protocol: every connection a client opens to the server starts with
// SendBinaryTransportString(token, kind), where kind is one of:
//
//	SG_Chan — control channel (server replies with the token)
//	SG_TCP  — data/tunnel connection (no reply)
//	SG_Ping — health probe (server replies with the token, then closes)

// TokenEqual compares two tokens in constant time.
func TokenEqual(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

// ReadHello reads the client's handshake header within timeout and checks the token.
// ok is false if the read failed or the token did not match.
func ReadHello(conn net.Conn, token string, timeout time.Duration) (kind byte, ok bool) {
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	msg, kind, err := ReceiveBinaryTransportString(conn)
	_ = conn.SetReadDeadline(time.Time{})
	if err != nil || !TokenEqual(msg, token) {
		return 0, false
	}
	return kind, true
}

// SendHello writes the client's handshake header.
func SendHello(conn net.Conn, token string, kind byte) error {
	return SendBinaryTransportString(conn, token, kind)
}

// ClientControlHandshake sends a control hello and waits for the server's token echo.
func ClientControlHandshake(conn net.Conn, token string, kind byte, timeout time.Duration) bool {
	if err := SendHello(conn, token, kind); err != nil {
		return false
	}
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	msg, _, err := ReceiveBinaryTransportString(conn)
	_ = conn.SetReadDeadline(time.Time{})
	return err == nil && TokenEqual(msg, token)
}
