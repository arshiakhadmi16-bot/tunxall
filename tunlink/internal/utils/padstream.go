package utils

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

// PaddedConn wraps a net.Conn and reshapes application bytes into frames with
// random padding so on-wire packet sizes are not 1:1 with real payload sizes.
//
// Frame layout (big-endian):
//
//	payload_len uint16
//	pad_len     uint16
//	payload     [payload_len]
//	padding     [pad_len]     // cryptographic random, discarded on read
//
// Empty payload frames (payload_len=0) are noise / cover traffic.
type PaddedConn struct {
	net.Conn
	maxPad     int // max random padding per frame (0..maxPad)
	maxPayload int // max app bytes per frame before split
	rbuf       []byte
	mu         sync.Mutex

	// optional cover traffic
	coverStop chan struct{}
}

// NewPaddedConn enables size obfuscation on an existing connection.
// maxPad: maximum padding bytes appended to each frame (e.g. 256–512).
// maxPayload: split large writes into chunks of at most this size (e.g. 1200).
func NewPaddedConn(c net.Conn, maxPad, maxPayload int) *PaddedConn {
	if maxPad < 0 {
		maxPad = 0
	}
	if maxPad > 2048 {
		maxPad = 2048
	}
	if maxPayload <= 0 || maxPayload > 8192 {
		maxPayload = 1200
	}
	return &PaddedConn{
		Conn:       c,
		maxPad:     maxPad,
		maxPayload: maxPayload,
	}
}

func (p *PaddedConn) randPadLen() int {
	if p.maxPad <= 0 {
		return 0
	}
	var b [2]byte
	if _, err := rand.Read(b[:]); err != nil {
		return 0
	}
	return int(binary.BigEndian.Uint16(b[:])) % (p.maxPad + 1)
}

func (p *PaddedConn) writeFrame(payload []byte) error {
	padN := p.randPadLen()
	// header 4 bytes + payload + pad
	total := 4 + len(payload) + padN
	buf := make([]byte, total)
	binary.BigEndian.PutUint16(buf[0:2], uint16(len(payload)))
	binary.BigEndian.PutUint16(buf[2:4], uint16(padN))
	copy(buf[4:], payload)
	if padN > 0 {
		if _, err := rand.Read(buf[4+len(payload):]); err != nil {
			// non-crypto fallback: leave zeros (still changes length)
		}
	}
	_, err := p.Conn.Write(buf)
	return err
}

func (p *PaddedConn) Write(b []byte) (int, error) {
	if len(b) == 0 {
		return 0, nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()

	sent := 0
	for sent < len(b) {
		n := len(b) - sent
		if n > p.maxPayload {
			n = p.maxPayload
		}
		// small random extra split (~20% chance to cut earlier) breaks steady sizes
		if n > 64 {
			var r [1]byte
			if _, err := rand.Read(r[:]); err == nil && r[0]%5 == 0 {
				cut := int(r[0])%(n/2) + n/2
				if cut < n && cut > 0 {
					n = cut
				}
			}
		}
		if err := p.writeFrame(b[sent : sent+n]); err != nil {
			return sent, err
		}
		sent += n
	}
	return sent, nil
}

func (p *PaddedConn) Read(b []byte) (int, error) {
	if len(p.rbuf) > 0 {
		n := copy(b, p.rbuf)
		p.rbuf = p.rbuf[n:]
		return n, nil
	}

	for {
		hdr := make([]byte, 4)
		if _, err := io.ReadFull(p.Conn, hdr); err != nil {
			return 0, err
		}
		payN := int(binary.BigEndian.Uint16(hdr[0:2]))
		padN := int(binary.BigEndian.Uint16(hdr[2:4]))
		if payN > 8192 || padN > 4096 {
			return 0, fmt.Errorf("padded frame too large: pay=%d pad=%d", payN, padN)
		}
		body := make([]byte, payN+padN)
		if _, err := io.ReadFull(p.Conn, body); err != nil {
			return 0, err
		}
		// skip pure noise frames
		if payN == 0 {
			continue
		}
		payload := body[:payN]
		n := copy(b, payload)
		if n < payN {
			p.rbuf = append(p.rbuf[:0], payload[n:]...)
		}
		return n, nil
	}
}

// StartCoverTraffic sends empty padded frames on an interval to muddy traffic analysis.
// Safe to call once; stop with Close or StopCover.
func (p *PaddedConn) StartCoverTraffic(interval time.Duration) {
	if interval <= 0 {
		interval = 3 * time.Second
	}
	p.mu.Lock()
	if p.coverStop != nil {
		p.mu.Unlock()
		return
	}
	p.coverStop = make(chan struct{})
	stop := p.coverStop
	p.mu.Unlock()

	go func() {
		t := time.NewTimer(interval)
		defer t.Stop()
		for {
			// jitter 50%..150% of interval
			var j [1]byte
			_, _ = rand.Read(j[:])
			next := time.Duration(50+int(j[0])%100) * interval / 100
			if next < time.Second {
				next = time.Second
			}
			t.Reset(next)
			select {
			case <-stop:
				return
			case <-t.C:
				p.mu.Lock()
				_ = p.writeFrame(nil) // noise frame
				p.mu.Unlock()
			}
		}
	}()
}

func (p *PaddedConn) StopCover() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.coverStop != nil {
		close(p.coverStop)
		p.coverStop = nil
	}
}

func (p *PaddedConn) Close() error {
	p.StopCover()
	return p.Conn.Close()
}
