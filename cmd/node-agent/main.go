package main

import (
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"hosting-control-panel/internal/nodeagent"
)

func main() {
	secret := os.Getenv("HCP_NODE_AGENT_SECRET")
	if len(secret) < 32 {
		log.Fatal("HCP_NODE_AGENT_SECRET must be at least 32 bytes")
	}

	listen := strings.TrimSpace(os.Getenv("HCP_NODE_AGENT_LISTEN"))
	if listen == "" {
		listen = "127.0.0.1:18210"
	}
	if err := requireLoopback(listen); err != nil {
		log.Fatal(err)
	}

	agent, err := nodeagent.New([]byte(secret))
	if err != nil {
		log.Fatal(err)
	}

	server := &http.Server{
		Addr:              listen,
		Handler:           agent.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	log.Printf("hcp node-agent protocol v1 listening on %s", listen)
	log.Fatal(server.ListenAndServe())
}

func requireLoopback(address string) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return errors.New("invalid HCP_NODE_AGENT_LISTEN")
	}
	if strings.EqualFold(host, "localhost") {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return errors.New("phase-03 node agent must bind to loopback only")
	}
	return nil
}
