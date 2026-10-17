package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"sort"
	"strings"
)

// protectedDaemonKeys are the baked daemon.json settings dockma depends on: a
// user's daemon.json can't change them. dockerd must listen where the agent
// proxies, keep its data on the data disk, and use nftables, the only
// firewall the kernel has.
var protectedDaemonKeys = []string{"hosts", "group", "data-root", "firewall-backend"}

// defaultLogOpts caps each container's json-file log at three 10 MB files,
// so a chatty container can't fill the data disk.
var defaultLogOpts = map[string]any{"max-size": "10m", "max-file": "3"}

// mergeDaemonConfig returns the dockerd configuration: baked, overlaid with
// the user's keys except the protected ones, plus dockma's defaults for keys
// the user didn't set. gateway is the Mac's address on the VM's network,
// which `host-gateway` resolves to; empty if unknown. The returned warnings
// name user keys that were ignored.
func mergeDaemonConfig(baked, user map[string]any, gateway string) (map[string]any, []string) {
	merged := map[string]any{}
	for k, v := range baked {
		merged[k] = v
	}
	var warnings []string
	for k, v := range user {
		if isProtectedDaemonKey(k) {
			warnings = append(warnings, fmt.Sprintf("ignoring %q in daemon.json: dockma sets it", k))
			continue
		}
		merged[k] = v
	}
	sort.Strings(warnings)
	// Other log drivers reject json-file's options.
	_, hasDriver := user["log-driver"]
	_, hasOpts := user["log-opts"]
	if !hasDriver && !hasOpts {
		merged["log-opts"] = defaultLogOpts
	}
	if _, ok := user["host-gateway-ips"]; !ok && gateway != "" {
		merged["host-gateway-ips"] = []any{gateway}
	}
	return merged, warnings
}

// isProtectedDaemonKey matches without case, as dockerd's decoding does.
func isProtectedDaemonKey(key string) bool {
	for _, p := range protectedDaemonKeys {
		if strings.EqualFold(key, p) {
			return true
		}
	}
	return false
}

// readJSONObject reads a JSON object from path; a missing file is an empty
// object.
func readJSONObject(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return map[string]any{}, nil
	}
	if err != nil {
		return nil, err
	}
	var object map[string]any
	if err := json.Unmarshal(data, &object); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return object, nil
}

// runDaemonConfig implements `dockma-agent daemon-config <baked> <user> <gateway file> <out>`,
// which the dockerd init script runs before each dockerd start. A user file
// that doesn't parse is skipped with a message; the init script validates
// the result with `dockerd --validate` and falls back to the baked file.
func runDaemonConfig(args []string) int {
	if len(args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: dockma-agent daemon-config <baked> <user> <gateway file> <out>")
		return 2
	}
	bakedPath, userPath, gatewayPath, outPath := args[0], args[1], args[2], args[3]
	baked, err := readJSONObject(bakedPath)
	if err != nil {
		log.Print(err)
		return 1
	}
	user, err := readJSONObject(userPath)
	if err != nil {
		log.Printf("ignoring the user's daemon.json: %v", err)
		user = map[string]any{}
	}
	gateway := ""
	if data, err := os.ReadFile(gatewayPath); err == nil {
		gateway = strings.TrimSpace(string(data))
	}
	merged, warnings := mergeDaemonConfig(baked, user, gateway)
	for _, w := range warnings {
		log.Print(w)
	}
	data, err := json.MarshalIndent(merged, "", "  ")
	if err != nil {
		log.Print(err)
		return 1
	}
	tmp := outPath + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o644); err != nil {
		log.Print(err)
		return 1
	}
	if err := os.Rename(tmp, outPath); err != nil {
		log.Print(err)
		return 1
	}
	return 0
}
