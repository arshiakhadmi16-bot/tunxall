package utils

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
)

// SendBinaryString sends a length-prefixed string (2-byte big-endian length + data).
func SendBinaryString(conn net.Conn, message string) error {
	buf := make([]byte, 2+len(message))
	binary.BigEndian.PutUint16(buf[:2], uint16(len(message)))
	copy(buf[2:], message)
	_, err := conn.Write(buf)
	if err != nil {
		return fmt.Errorf("failed to send message: %w", err)
	}
	return nil
}

// ReceiveBinaryString receives a length-prefixed string.
func ReceiveBinaryString(conn net.Conn) (string, error) {
	lenBuf := make([]byte, 2)
	if _, err := io.ReadFull(conn, lenBuf); err != nil {
		return "", fmt.Errorf("failed to read message length: %w", err)
	}
	messageLength := binary.BigEndian.Uint16(lenBuf)
	messageBuf := make([]byte, messageLength)
	if _, err := io.ReadFull(conn, messageBuf); err != nil {
		return "", fmt.Errorf("failed to read message: %w", err)
	}
	return string(messageBuf), nil
}

// SendBinaryTransportString sends length (2) + transport type (1) + data.
func SendBinaryTransportString(conn net.Conn, message string, transport byte) error {
	buf := make([]byte, 3+len(message))
	binary.BigEndian.PutUint16(buf[:2], uint16(len(message)))
	buf[2] = transport
	copy(buf[3:], message)
	_, err := conn.Write(buf)
	if err != nil {
		return fmt.Errorf("failed to send transport message: %w", err)
	}
	return nil
}

// ReceiveBinaryTransportString receives length + transport + data.
func ReceiveBinaryTransportString(conn net.Conn) (string, byte, error) {
	lenBuf := make([]byte, 3)
	if _, err := io.ReadFull(conn, lenBuf); err != nil {
		return "", 0, fmt.Errorf("failed to read transport header: %w", err)
	}
	messageLength := binary.BigEndian.Uint16(lenBuf[:2])
	transport := lenBuf[2]
	messageBuf := make([]byte, messageLength)
	if _, err := io.ReadFull(conn, messageBuf); err != nil {
		return "", 0, fmt.Errorf("failed to read transport message: %w", err)
	}
	return string(messageBuf), transport, nil
}

// SendBinaryByte sends a single byte.
func SendBinaryByte(conn net.Conn, message byte) error {
	_, err := conn.Write([]byte{message})
	return err
}

// ReceiveBinaryByte receives a single byte.
func ReceiveBinaryByte(conn net.Conn) (byte, error) {
	buf := make([]byte, 1)
	_, err := io.ReadFull(conn, buf)
	if err != nil {
		return 0, err
	}
	return buf[0], nil
}

// SendBinaryInt sends a uint16 as 2-byte big-endian.
func SendBinaryInt(conn net.Conn, val uint16) error {
	buf := make([]byte, 2)
	binary.BigEndian.PutUint16(buf, val)
	_, err := conn.Write(buf)
	return err
}

// ReceiveBinaryInt receives a uint16.
func ReceiveBinaryInt(conn net.Conn) (uint16, error) {
	var val uint16
	err := binary.Read(conn, binary.BigEndian, &val)
	return val, err
}
