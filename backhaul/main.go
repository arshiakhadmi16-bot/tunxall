package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/musix/backhaul-rewrite/cmd"
	"github.com/musix/backhaul-rewrite/internal/utils"
)

const version = "v0.1.0-rewrite"

func main() {
	configPath := flag.String("c", "", "path to the configuration file (TOML format)")
	showVersion := flag.Bool("v", false, "print the version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Println(version)
		os.Exit(0)
	}

	if *configPath == "" {
		fmt.Fprintf(os.Stderr, "Usage: %s -c /path/to/config.toml\n", os.Args[0])
		os.Exit(1)
	}

	logger := utils.NewLogger("info")

	// Validate up front so a broken config fails fast with a clear message.
	if _, err := cmd.LoadConfig(*configPath); err != nil {
		logger.Fatalf("failed to load config: %v", err)
	}

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

	// runCancel stops the currently running instance; it is only touched by this
	// goroutine (start / reload / shutdown all happen in the select loop below).
	runCtx, runCancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { cmd.Run(*configPath, runCtx); close(done) }()

	// Simple hot-reload watcher
	lastMod, _ := getModTime(*configPath)
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-sigChan:
			runCancel()
			select {
			case <-done:
			case <-time.After(3 * time.Second):
			}
			return
		case <-ticker.C:
			mod, err := getModTime(*configPath)
			if err != nil || !mod.After(lastMod) {
				continue
			}
			lastMod = mod
			if _, err := cmd.LoadConfig(*configPath); err != nil {
				logger.Errorf("config changed but is invalid, keeping the running instance: %v", err)
				continue
			}
			logger.Info("config changed, reloading...")
			runCancel()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
			}
			time.Sleep(500 * time.Millisecond) // let listeners release their ports
			runCtx, runCancel = context.WithCancel(context.Background())
			done = make(chan struct{})
			go func(ctx context.Context, d chan struct{}) { cmd.Run(*configPath, ctx); close(d) }(runCtx, done)
		}
	}
}

func getModTime(path string) (time.Time, error) {
	abs, _ := filepath.Abs(path)
	info, err := os.Stat(abs)
	if err != nil {
		return time.Time{}, err
	}
	return info.ModTime(), nil
}
