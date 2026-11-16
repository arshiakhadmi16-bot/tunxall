package wsconn

import (
	"net"
	"time"

	"github.com/gorilla/websocket"
)

// NetConn adapts websocket.Conn to net.Conn
type NetConn struct {
	Conn *websocket.Conn
	rbuf []byte
}

func (c *NetConn) Read(b []byte) (int, error) {
	if len(c.rbuf) > 0 {
		n := copy(b, c.rbuf)
		c.rbuf = c.rbuf[n:]
		return n, nil
	}
	_, msg, err := c.Conn.ReadMessage()
	if err != nil {
		return 0, err
	}
	n := copy(b, msg)
	if n < len(msg) {
		c.rbuf = msg[n:]
	}
	return n, nil
}

func (c *NetConn) Write(b []byte) (int, error) {
	err := c.Conn.WriteMessage(websocket.BinaryMessage, b)
	if err != nil {
		return 0, err
	}
	return len(b), nil
}

func (c *NetConn) Close() error         { return c.Conn.Close() }
func (c *NetConn) LocalAddr() net.Addr  { return c.Conn.LocalAddr() }
func (c *NetConn) RemoteAddr() net.Addr { return c.Conn.RemoteAddr() }
func (c *NetConn) SetDeadline(t time.Time) error {
	if err := c.Conn.SetReadDeadline(t); err != nil {
		return err
	}
	return c.Conn.SetWriteDeadline(t)
}
func (c *NetConn) SetReadDeadline(t time.Time) error  { return c.Conn.SetReadDeadline(t) }
func (c *NetConn) SetWriteDeadline(t time.Time) error { return c.Conn.SetWriteDeadline(t) }
