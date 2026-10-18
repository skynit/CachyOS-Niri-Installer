package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestRead(t *testing.T) {
	dir := t.TempDir()
	if values := read(dir); values == nil || len(values) != 0 {
		t.Fatalf("empty records = %v", values)
	}
	for _, file := range []struct{ name, content string }{{"a.json", `{"id":"a"}`}, {"b.json", `{"id":"b"}`}} {
		if err := os.WriteFile(filepath.Join(dir, file.name), []byte(file.content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	values := read(dir)
	if len(values) != 2 || !strings.Contains(string(values[0]), `"a"`) {
		t.Fatalf("sorted records = %s", values)
	}
	if err := os.WriteFile(filepath.Join(dir, "broken.json"), []byte("invalid"), 0600); err != nil {
		t.Fatal(err)
	}
	if values := read(dir); len(values) != 0 {
		t.Fatalf("bad JSON should not pass through: %s", values)
	}
}

func TestCheck(t *testing.T) {
	for _, input := range []string{"not-json", "null", "false", ""} {
		if _, err := record([]byte(input)); err == nil {
			t.Errorf("accepted %q", input)
		}
	}
	if _, err := record([]byte(`{"stats":{},"ready":true}`)); err != nil {
		t.Fatal(err)
	}
}

func TestMergePreservesStatistics(t *testing.T) {
	old := []byte(`{"stats":{"tokens":9007199254740993},"ready":true,"limits":{"window":{"old":1},"keep":2},"tierLabel":"old"}`)
	update := []byte(`{"stats":{},"limits":{"window":{"new":3}},"usageStatusText":"fresh","tierLabel":"new","updatedAt":123}`)
	data, err := merged(old, update)
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]json.RawMessage
	if json.Unmarshal(data, &result) != nil || !strings.Contains(string(result["stats"]), "9007199254740993") {
		t.Fatalf("lost old statistics or precision: %s", data)
	}
	var limits map[string]json.RawMessage
	if json.Unmarshal(result["limits"], &limits) != nil || string(limits["keep"]) != "2" {
		t.Fatalf("lost retained limit fields: %s", result["limits"])
	}
	var window map[string]int
	if json.Unmarshal(limits["window"], &window) != nil || !reflect.DeepEqual(window, map[string]int{"old": 1, "new": 3}) {
		t.Fatalf("new window was not applied: %s", limits["window"])
	}
	if string(result["tierLabel"]) != `"new"` || string(result["usageStatusText"]) != `"fresh"` {
		t.Fatalf("lost new fields: %s", data)
	}
}
