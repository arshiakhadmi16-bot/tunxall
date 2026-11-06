package config

// TransportType defines the type of transport.
type TransportType string

const (
	TCP    TransportType = "tcp"
	TCPMUX TransportType = "tcpmux"
	WS     TransportType = "ws"
	WSS    TransportType = "wss"
	WSMUX  TransportType = "wsmux"
	WSSMUX TransportType = "wssmux"
	UDP    TransportType = "udp"
	GRPC   TransportType = "grpc"  // gRPC over plaintext HTTP/2 (h2c)
	GRPCS  TransportType = "grpcs" // gRPC over TLS
)

// ServerConfig represents the configuration for the server.
type ServerConfig struct {
	BindAddr         string        `toml:"bind_addr"`
	Transport        TransportType `toml:"transport"`
	Token            string        `toml:"token"`
	Nodelay          bool          `toml:"nodelay"`
	Keepalive        int           `toml:"keepalive_period"`
	ChannelSize      int           `toml:"channel_size"`
	LogLevel         string        `toml:"log_level"`
	Ports            []string      `toml:"ports"`
	MuxVersion       int           `toml:"mux_version"`
	MaxFrameSize     int           `toml:"mux_framesize"`
	MaxReceiveBuffer int           `toml:"mux_recievebuffer"`
	MaxStreamBuffer  int           `toml:"mux_streambuffer"`
	Sniffer          bool          `toml:"sniffer"`
	WebPort          int           `toml:"web_port"`
	SnifferLog       string        `toml:"sniffer_log"`
	TLSCertFile      string        `toml:"tls_cert"`
	TLSKeyFile       string        `toml:"tls_key"`
	Heartbeat        int           `toml:"heartbeat"`
	MuxCon           int           `toml:"mux_con"`
	AcceptUDP        bool          `toml:"accept_udp"`
	SkipOptz         bool          `toml:"skip_optz"`
	MSS              int           `toml:"mss"`
	SO_RCVBUF        int           `toml:"so_rcvbuf"`
	SO_SNDBUF        int           `toml:"so_sndbuf"`
	ProxyProtocol    bool          `toml:"proxy_protocol"`
}

// ClientConfig represents the configuration for the client.
type ClientConfig struct {
	// Single server (backward compatible)
	RemoteAddr string `toml:"remote_addr"`

	// Multiple servers for auto-selection
	// Example: remote_addrs = ["1.1.1.1:3080", "2.2.2.2:3080"]
	RemoteAddrs []string `toml:"remote_addrs"`

	Transport        TransportType `toml:"transport"`
	Token            string        `toml:"token"`
	ConnectionPool   int           `toml:"connection_pool"`
	RetryInterval    int           `toml:"retry_interval"`
	Nodelay          bool          `toml:"nodelay"`
	Keepalive        int           `toml:"keepalive_period"`
	LogLevel         string        `toml:"log_level"`
	MuxVersion       int           `toml:"mux_version"`
	MaxFrameSize     int           `toml:"mux_framesize"`
	MaxReceiveBuffer int           `toml:"mux_recievebuffer"`
	MaxStreamBuffer  int           `toml:"mux_streambuffer"`
	Sniffer          bool          `toml:"sniffer"`
	WebPort          int           `toml:"web_port"`
	SnifferLog       string        `toml:"sniffer_log"`
	DialTimeout      int           `toml:"dial_timeout"`
	AggressivePool   bool          `toml:"aggressive_pool"`
	EdgeIP           string        `toml:"edge_ip"`
	SkipOptz         bool          `toml:"skip_optz"`
	MSS              int           `toml:"mss"`
	SO_RCVBUF        int           `toml:"so_rcvbuf"`
	SO_SNDBUF        int           `toml:"so_sndbuf"`

	// Auto server selection
	HealthCheckInterval int `toml:"health_check_interval"` // seconds, default 30
	HealthCheckTimeout  int `toml:"health_check_timeout"`  // seconds, default 3
	MinSuccessRate      int `toml:"min_success_rate"`      // percent 0-100, default 70
	SwitchThresholdMs   int `toml:"switch_threshold_ms"`   // only switch if better by this RTT (ms), default 50
}

// Config represents the complete configuration.
type Config struct {
	Server ServerConfig `toml:"server"`
	Client ClientConfig `toml:"client"`
}

// GetRemoteAddrs returns the list of remote addresses.
func (c *ClientConfig) GetRemoteAddrs() []string {
	if len(c.RemoteAddrs) > 0 {
		return c.RemoteAddrs
	}
	if c.RemoteAddr != "" {
		return []string{c.RemoteAddr}
	}
	return nil
}
