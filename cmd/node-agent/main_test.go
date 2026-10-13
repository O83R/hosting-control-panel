package main

import "testing"

func TestRequireLoopback(t *testing.T) {
	for _, address := range []string{"127.0.0.1:18210", "[::1]:18210", "localhost:18210"} {
		if err := requireLoopback(address); err != nil {
			t.Fatalf("loopback address %q rejected: %v", address, err)
		}
	}

	for _, address := range []string{"0.0.0.0:18210", ":18210", "192.0.2.10:18210"} {
		if err := requireLoopback(address); err == nil {
			t.Fatalf("non-loopback address %q accepted", address)
		}
	}
}
