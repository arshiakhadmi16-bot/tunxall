// Package grpcconn carries tunnel connections over gRPC.
//
// The service is a single bidirectional-streaming method; every stream is one
// tunnel connection (control, data or health probe) and is exposed as a net.Conn.
// Messages are standard protobuf BytesValue, so no generated code is needed and
// the traffic is ordinary gRPC (content-type application/grpc over HTTP/2).
package grpcconn

import (
	"context"
	"net"
	"os"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

const (
	ServiceName = "tunxall.Tunnel"
	MethodName  = "Stream"
	FullMethod  = "/" + ServiceName + "/" + MethodName
)

var streamDesc = grpc.StreamDesc{
	StreamName:    MethodName,
	ServerStreams: true,
	ClientStreams: true,
}

// msgStream is what grpc.ServerStream and grpc.ClientStream have in common.
type msgStream interface {
	SendMsg(m any) error
	RecvMsg(m any) error
}

// Conn adapts a gRPC stream to net.Conn. Reads honour SetReadDeadline (a timeout
// does not break the stream); write deadlines are not supported and ignored.
type Conn struct {
	stream  msgStream
	onClose func()
	local   net.Addr
	remote  net.Addr

	readOnce sync.Once
	msgs     chan []byte
	readErr  error // valid once msgs is closed
	rbuf     []byte

	mu           sync.Mutex
	readDeadline time.Time

	closeOnce sync.Once
	closed    chan struct{}
}

func newConn(s msgStream, local, remote net.Addr, onClose func()) *Conn {
	return &Conn{
		stream:  s,
		onClose: onClose,
		local:   local,
		remote:  remote,
		msgs:    make(chan []byte, 16),
		closed:  make(chan struct{}),
	}
}

func (c *Conn) startReader() {
	go func() {
		defer close(c.msgs)
		for {
			m := new(wrapperspb.BytesValue)
			if err := c.stream.RecvMsg(m); err != nil {
				c.readErr = err
				return
			}
			if len(m.Value) == 0 {
				continue
			}
			select {
			case c.msgs <- m.Value:
			case <-c.closed:
				c.readErr = net.ErrClosed
				return
			}
		}
	}()
}

func (c *Conn) Read(b []byte) (int, error) {
	if len(c.rbuf) > 0 {
		n := copy(b, c.rbuf)
		c.rbuf = c.rbuf[n:]
		return n, nil
	}
	c.readOnce.Do(c.startReader)

	var timeout <-chan time.Time
	c.mu.Lock()
	dl := c.readDeadline
	c.mu.Unlock()
	if !dl.IsZero() {
		d := time.Until(dl)
		if d <= 0 {
			return 0, os.ErrDeadlineExceeded
		}
		t := time.NewTimer(d)
		defer t.Stop()
		timeout = t.C
	}

	select {
	case msg, ok := <-c.msgs:
		if !ok {
			return 0, c.readErr
		}
		n := copy(b, msg)
		c.rbuf = msg[n:]
		return n, nil
	case <-timeout:
		return 0, os.ErrDeadlineExceeded
	case <-c.closed:
		return 0, net.ErrClosed
	}
}

func (c *Conn) Write(b []byte) (int, error) {
	select {
	case <-c.closed:
		return 0, net.ErrClosed
	default:
	}
	// SendMsg serialises the message before returning, so b may be reused afterwards.
	if err := c.stream.SendMsg(wrapperspb.Bytes(b)); err != nil {
		return 0, err
	}
	return len(b), nil
}

func (c *Conn) Close() error {
	c.closeOnce.Do(func() {
		close(c.closed)
		if c.onClose != nil {
			c.onClose()
		}
	})
	return nil
}

// Done is closed when the connection is closed.
func (c *Conn) Done() <-chan struct{} { return c.closed }

func (c *Conn) LocalAddr() net.Addr  { return c.local }
func (c *Conn) RemoteAddr() net.Addr { return c.remote }

func (c *Conn) SetDeadline(t time.Time) error { return c.SetReadDeadline(t) }

func (c *Conn) SetReadDeadline(t time.Time) error {
	c.mu.Lock()
	c.readDeadline = t
	c.mu.Unlock()
	return nil
}

func (c *Conn) SetWriteDeadline(time.Time) error { return nil }

type streamAddr string

func (a streamAddr) Network() string { return "grpc" }
func (a streamAddr) String() string  { return string(a) }

// RegisterServer registers the tunnel service. handle is called for every new
// stream; the stream stays open until the returned Conn is closed.
func RegisterServer(s *grpc.Server, localAddr string, handle func(*Conn)) {
	desc := grpc.ServiceDesc{
		ServiceName: ServiceName,
		HandlerType: (*any)(nil),
		Streams: []grpc.StreamDesc{{
			StreamName:    MethodName,
			ServerStreams: true,
			ClientStreams: true,
			Handler: func(_ any, stream grpc.ServerStream) error {
				remote := "unknown"
				if p, ok := peerAddr(stream.Context()); ok {
					remote = p
				}
				conn := newConn(stream, streamAddr(localAddr), streamAddr(remote), nil)
				go handle(conn)
				select {
				case <-conn.Done():
				case <-stream.Context().Done():
					conn.Close()
				}
				return nil
			},
		}},
	}
	s.RegisterService(&desc, struct{}{})
}

// OpenStream opens a new tunnel stream on cc. Closing the Conn ends the stream.
func OpenStream(ctx context.Context, cc *grpc.ClientConn) (*Conn, error) {
	sctx, cancel := context.WithCancel(ctx)
	stream, err := cc.NewStream(sctx, &streamDesc, FullMethod)
	if err != nil {
		cancel()
		return nil, err
	}
	return newConn(stream, streamAddr("client"), streamAddr(cc.Target()), func() {
		_ = stream.CloseSend()
		cancel()
	}), nil
}
