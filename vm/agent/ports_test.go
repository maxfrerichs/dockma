package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestPublishedPorts(t *testing.T) {
	const fixture = `[
	  {"Ports": [
	    {"IP": "0.0.0.0", "PrivatePort": 80, "PublicPort": 8080, "Type": "tcp"},
	    {"IP": "::", "PrivatePort": 80, "PublicPort": 8080, "Type": "tcp"},
	    {"PrivatePort": 9000, "Type": "tcp"},
	    {"IP": "0.0.0.0", "PrivatePort": 53, "PublicPort": 5353, "Type": "udp"}
	  ]},
	  {"Ports": [
	    {"IP": "::", "PrivatePort": 443, "PublicPort": 8443, "Type": "tcp"},
	    {"IP": "127.0.0.1", "PrivatePort": 5432, "PublicPort": 5432, "Type": "tcp"}
	  ]},
	  {"Ports": []}
	]`
	var containers []Container
	if err := json.Unmarshal([]byte(fixture), &containers); err != nil {
		t.Fatal(err)
	}
	got := PublishedPorts(containers)
	want := []ForwardedPort{
		{Port: 5432, Target: "127.0.0.1:5432"},
		{Port: 8080, Target: "127.0.0.1:8080"},
		{Port: 8443, Target: "[::1]:8443"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestPublishedPortsIPv6First(t *testing.T) {
	containers := []Container{{Ports: []ContainerPort{
		{IP: "::", PublicPort: 80, Type: "tcp"},
		{IP: "0.0.0.0", PublicPort: 80, Type: "tcp"},
	}}}
	got := PublishedPorts(containers)
	want := []ForwardedPort{{Port: 80, Target: "127.0.0.1:80"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestPublishedPortsEmpty(t *testing.T) {
	if got := PublishedPorts(nil); len(got) != 0 {
		t.Fatalf("got %+v, want empty", got)
	}
}
