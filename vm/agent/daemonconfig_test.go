package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

var bakedDaemonConfig = map[string]any{
	"hosts":            []any{"unix:///var/run/docker.sock"},
	"group":            "root",
	"firewall-backend": "nftables",
	"data-root":        "/var/lib/docker",
}

func TestMergeDaemonConfigAddsDefaults(t *testing.T) {
	merged, warnings := mergeDaemonConfig(bakedDaemonConfig, map[string]any{}, "192.168.64.1")
	if len(warnings) != 0 {
		t.Errorf("warnings = %v", warnings)
	}
	if !reflect.DeepEqual(merged["log-opts"], defaultLogOpts) {
		t.Errorf("log-opts = %v", merged["log-opts"])
	}
	if !reflect.DeepEqual(merged["host-gateway-ips"], []any{"192.168.64.1"}) {
		t.Errorf("host-gateway-ips = %v", merged["host-gateway-ips"])
	}
	if merged["firewall-backend"] != "nftables" {
		t.Errorf("baked key lost: %v", merged)
	}
}

func TestMergeDaemonConfigKeepsProtectedKeys(t *testing.T) {
	user := map[string]any{"Data-Root": "/elsewhere", "hosts": []any{"tcp://0.0.0.0:2375"}, "registry-mirrors": []any{"https://mirror.example"}}
	merged, warnings := mergeDaemonConfig(bakedDaemonConfig, user, "")
	if merged["data-root"] != "/var/lib/docker" || !reflect.DeepEqual(merged["hosts"], bakedDaemonConfig["hosts"]) {
		t.Errorf("protected keys overridden: %v", merged)
	}
	if len(warnings) != 2 {
		t.Errorf("warnings = %v, want one per protected key", warnings)
	}
	if !reflect.DeepEqual(merged["registry-mirrors"], user["registry-mirrors"]) {
		t.Errorf("user key dropped: %v", merged)
	}
	if _, ok := merged["host-gateway-ips"]; ok {
		t.Errorf("host-gateway-ips set without a known gateway")
	}
}

func TestMergeDaemonConfigLeavesUserLoggingAlone(t *testing.T) {
	merged, _ := mergeDaemonConfig(bakedDaemonConfig, map[string]any{"log-driver": "local"}, "")
	if _, ok := merged["log-opts"]; ok {
		t.Errorf("json-file log-opts added for another log driver: %v", merged)
	}
	userOpts := map[string]any{"max-size": "1g"}
	merged, _ = mergeDaemonConfig(bakedDaemonConfig, map[string]any{"log-opts": userOpts}, "")
	if !reflect.DeepEqual(merged["log-opts"], userOpts) {
		t.Errorf("log-opts = %v, want the user's", merged["log-opts"])
	}
	gateways := []any{"10.0.0.1"}
	merged, _ = mergeDaemonConfig(bakedDaemonConfig, map[string]any{"host-gateway-ips": gateways}, "192.168.64.1")
	if !reflect.DeepEqual(merged["host-gateway-ips"], gateways) {
		t.Errorf("host-gateway-ips = %v, want the user's", merged["host-gateway-ips"])
	}
}

func TestRunDaemonConfigSkipsAnInvalidUserFile(t *testing.T) {
	dir := t.TempDir()
	baked := filepath.Join(dir, "baked.json")
	user := filepath.Join(dir, "user.json")
	gateway := filepath.Join(dir, "gateway")
	out := filepath.Join(dir, "out.json")
	data, _ := json.Marshal(bakedDaemonConfig)
	os.WriteFile(baked, data, 0o644)
	os.WriteFile(user, []byte(`{"debug": true,`), 0o644)
	os.WriteFile(gateway, []byte("192.168.64.1\n"), 0o644)
	if code := runDaemonConfig([]string{baked, user, gateway, out}); code != 0 {
		t.Fatalf("exit code %d", code)
	}
	merged, err := readJSONObject(out)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := merged["debug"]; ok || merged["data-root"] != "/var/lib/docker" {
		t.Errorf("merged = %v", merged)
	}
	if !reflect.DeepEqual(merged["host-gateway-ips"], []any{"192.168.64.1"}) {
		t.Errorf("host-gateway-ips = %v", merged["host-gateway-ips"])
	}
	// No user file at all is the common case.
	if code := runDaemonConfig([]string{baked, filepath.Join(dir, "missing.json"), gateway, out}); code != 0 {
		t.Fatalf("exit code %d without a user file", code)
	}
}
