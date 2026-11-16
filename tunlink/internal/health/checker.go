package health

import (
	"context"
	"net"
	"sync"
	"time"

	"github.com/musix/backhaul-rewrite/internal/utils"

	"github.com/sirupsen/logrus"
)

// DialFunc opens a raw connection to a server for probing (TCP, or a websocket for ws/wss).
type DialFunc func(ctx context.Context, addr string, timeout time.Duration) (net.Conn, error)

// ServerStats holds statistics for one remote server.
type ServerStats struct {
	Addr            string
	SuccessCount    int
	FailCount       int
	TotalRTT        time.Duration
	LastRTT         time.Duration
	LastCheck       time.Time
	ConsecutiveFail int
	mu              sync.RWMutex
}

// statsView is a consistent, lock-free copy of ServerStats.
type statsView struct {
	successRate     float64
	avgRTT          time.Duration
	lastRTT         time.Duration
	success, fail   int
	consecutiveFail int
}

func (v statsView) total() int { return v.success + v.fail }

// Score is higher for better servers: success_rate / (1 + rtt_ms/100).
func (v statsView) score() float64 {
	rttMs := float64(v.avgRTT.Milliseconds())
	return v.successRate / (1.0 + rttMs/100.0)
}

func (s *ServerStats) view() statsView {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v := statsView{
		lastRTT:         s.LastRTT,
		success:         s.SuccessCount,
		fail:            s.FailCount,
		consecutiveFail: s.ConsecutiveFail,
		avgRTT:          time.Hour, // "very high" until the first success
	}
	if total := s.SuccessCount + s.FailCount; total > 0 {
		v.successRate = float64(s.SuccessCount) / float64(total) * 100
	}
	if s.SuccessCount > 0 {
		v.avgRTT = s.TotalRTT / time.Duration(s.SuccessCount)
	}
	return v
}

func (s *ServerStats) SuccessRate() float64  { return s.view().successRate }
func (s *ServerStats) AvgRTT() time.Duration { return s.view().avgRTT }
func (s *ServerStats) Score() float64        { return s.view().score() }

// Checker periodically tests a list of servers and selects the best one.
type Checker struct {
	addrs           []string
	token           string
	interval        time.Duration
	timeout         time.Duration
	minSuccessRate  float64
	switchThreshold time.Duration
	logger          *logrus.Logger
	dial            DialFunc

	stats       map[string]*ServerStats
	currentAddr string
	mu          sync.RWMutex
	onSwitch    func(oldAddr, newAddr string)
}

func NewChecker(addrs []string, token string, intervalSec, timeoutSec, minSuccessRate, switchThresholdMs int, dial DialFunc, logger *logrus.Logger) *Checker {
	if intervalSec <= 0 {
		intervalSec = 30
	}
	if timeoutSec <= 0 {
		timeoutSec = 3
	}
	if minSuccessRate <= 0 {
		minSuccessRate = 70
	}
	if switchThresholdMs <= 0 {
		switchThresholdMs = 50
	}
	if dial == nil {
		dial = func(ctx context.Context, addr string, timeout time.Duration) (net.Conn, error) {
			d := net.Dialer{Timeout: timeout}
			return d.DialContext(ctx, "tcp", addr)
		}
	}

	stats := make(map[string]*ServerStats)
	for _, a := range addrs {
		stats[a] = &ServerStats{Addr: a}
	}

	return &Checker{
		addrs:           addrs,
		token:           token,
		interval:        time.Duration(intervalSec) * time.Second,
		timeout:         time.Duration(timeoutSec) * time.Second,
		minSuccessRate:  float64(minSuccessRate),
		switchThreshold: time.Duration(switchThresholdMs) * time.Millisecond,
		logger:          logger,
		dial:            dial,
		stats:           stats,
		currentAddr:     addrs[0], // start with first
	}
}

// SetOnSwitch registers a callback when the preferred server changes.
func (c *Checker) SetOnSwitch(fn func(oldAddr, newAddr string)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.onSwitch = fn
}

// Current returns the currently preferred server address.
func (c *Checker) Current() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.currentAddr
}

// Start begins periodic health checks.
func (c *Checker) Start(ctx context.Context) {
	c.runCheck(ctx)

	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.runCheck(ctx)
		}
	}
}

func (c *Checker) runCheck(ctx context.Context) {
	var wg sync.WaitGroup
	for _, addr := range c.addrs {
		wg.Add(1)
		go func(a string) {
			defer wg.Done()
			c.checkOne(ctx, a)
		}(addr)
	}
	wg.Wait()
	if ctx.Err() == nil {
		c.selectBest()
	}
}

// probe performs one handshake (SG_Ping) and returns the round-trip time.
func (c *Checker) probe(ctx context.Context, addr string) (time.Duration, error) {
	start := time.Now()
	conn, err := c.dial(ctx, addr, c.timeout)
	if err != nil {
		return 0, err
	}
	defer conn.Close()

	_ = conn.SetDeadline(time.Now().Add(c.timeout))
	if err := utils.SendHello(conn, c.token, utils.SG_Ping); err != nil {
		return 0, err
	}
	msg, _, err := utils.ReceiveBinaryTransportString(conn)
	if err != nil {
		return 0, err
	}
	if !utils.TokenEqual(msg, c.token) {
		return 0, errBadToken
	}
	return time.Since(start), nil
}

type probeError string

func (e probeError) Error() string { return string(e) }

const errBadToken = probeError("server replied with a different token")

func (c *Checker) checkOne(ctx context.Context, addr string) {
	rtt, err := c.probe(ctx, addr)
	st := c.stats[addr]

	st.mu.Lock()
	st.LastCheck = time.Now()
	if err != nil {
		st.FailCount++
		st.ConsecutiveFail++
	} else {
		st.SuccessCount++
		st.ConsecutiveFail = 0
		st.LastRTT = rtt
		st.TotalRTT += rtt
	}
	st.mu.Unlock()

	if err != nil {
		c.logger.Debugf("health check failed for %s: %v", addr, err)
	} else {
		c.logger.Debugf("health check OK %s  RTT=%v  success_rate=%.1f%%", addr, rtt, st.SuccessRate())
	}
}

func (c *Checker) selectBest() {
	views := make(map[string]statsView, len(c.addrs))
	for _, addr := range c.addrs {
		views[addr] = c.stats[addr].view()
	}

	var bestAddr string
	bestScore := -1.0
	for _, addr := range c.addrs {
		v := views[addr]
		// Skip servers below minimum success rate (once we have enough samples)
		if v.successRate < c.minSuccessRate && v.total() > 3 {
			continue
		}
		if s := v.score(); s > bestScore {
			bestScore, bestAddr = s, addr
		}
	}
	// Fallback: pick the one with highest score even if below threshold
	if bestAddr == "" {
		for _, addr := range c.addrs {
			if s := views[addr].score(); s > bestScore {
				bestScore, bestAddr = s, addr
			}
		}
	}
	if bestAddr == "" {
		return
	}

	c.mu.Lock()
	old := c.currentAddr
	if bestAddr == old {
		c.mu.Unlock()
		return
	}
	oldV, newV := views[old], views[bestAddr]

	switchNow := false
	if oldV.consecutiveFail >= 3 {
		// Force switch if current has many consecutive failures
		c.logger.Warnf("current server %s has %d consecutive failures → switching to %s", old, oldV.consecutiveFail, bestAddr)
		switchNow = true
	} else if newV.avgRTT+c.switchThreshold < oldV.avgRTT || newV.successRate > oldV.successRate+10 {
		// Switch if new server has better score and RTT improvement is meaningful
		c.logger.Infof("switching preferred server: %s (score=%.1f RTT=%v) → %s (score=%.1f RTT=%v)",
			old, oldV.score(), oldV.avgRTT, bestAddr, newV.score(), newV.avgRTT)
		switchNow = true
	}
	if switchNow {
		c.currentAddr = bestAddr
	}
	cb := c.onSwitch
	c.mu.Unlock()

	// Call outside the lock: the callback may call Current() or block for a while.
	if switchNow && cb != nil {
		cb(old, bestAddr)
	}
}

// StatsSnapshot returns a copy of current stats for logging/UI.
func (c *Checker) StatsSnapshot() map[string]map[string]interface{} {
	cur := c.Current()
	out := make(map[string]map[string]interface{})
	for addr, st := range c.stats {
		v := st.view()
		out[addr] = map[string]interface{}{
			"success_rate":     v.successRate,
			"avg_rtt_ms":       v.avgRTT.Milliseconds(),
			"last_rtt_ms":      v.lastRTT.Milliseconds(),
			"success":          v.success,
			"fail":             v.fail,
			"consecutive_fail": v.consecutiveFail,
			"score":            v.score(),
			"is_current":       addr == cur,
		}
	}
	return out
}
