package utils

const (
	SG_HB     byte = iota // Heartbeat
	SG_Chan               // Request a new connection
	SG_Ping               // Ping
	SG_Closed             // Closed channel
	SG_TCP                // TCP Transport ID
	SG_UDP                // UDP Transport ID
	SG_RTT                // RTT measurement
)
