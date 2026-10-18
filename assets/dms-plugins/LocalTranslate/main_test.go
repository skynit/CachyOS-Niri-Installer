package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func dictionary() string { return filepath.Join("data", "dictionary.sqlite3") }

func entries(value map[string]any) []entry { return value["entries"].([]entry) }

func TestChineseAndEnglish(t *testing.T) {
	for _, input := range []struct{ text, direction, translation string }{
		{"你好", "zh", "hello"},
		{"computer", "en", "电脑"},
		{"good morning", "en", "早上好"},
	} {
		value := search(input.text, "auto", dictionary())
		if value["status"] != "ready" || value["direction"] != input.direction {
			t.Fatalf("%q: %v", input.text, value)
		}
		found := false
		for _, item := range entries(value) {
			found = found || strings.Contains(item.Translation, input.translation)
		}
		if !found {
			t.Errorf("%q has no translation %q", input.text, input.translation)
		}
	}
	if !reflect.DeepEqual(entries(search("電腦", "auto", dictionary())), entries(search("电脑", "auto", dictionary()))) {
		t.Fatal("traditional and simplified index mismatch")
	}
}

func TestNormalizationAndLimits(t *testing.T) {
	if !reflect.DeepEqual(entries(search("  ＨＥＬＬＯ！ ", "auto", dictionary())), entries(search("hello", "auto", dictionary()))) {
		t.Fatal("NFKC and case folding changed")
	}
	if !reflect.DeepEqual(entries(search("good   morning!", "auto", dictionary())), entries(search("good morning", "auto", dictionary()))) {
		t.Fatal("whitespace normalization changed")
	}
	if value := search("词"+strings.Repeat("a", 200), "auto", dictionary()); value["reason"] != "input_too_long" {
		t.Errorf("input limit = %v", value)
	}
	if value := search("  ", "auto", dictionary()); value["status"] != "idle" {
		t.Errorf("empty query = %v", value)
	}
	if value := search("🙂", "auto", dictionary()); value["reason"] != "unsupported_input" {
		t.Errorf("unsupported query = %v", value)
	}
}

func TestSuggestionsAndBounds(t *testing.T) {
	value := search("translat", "auto", dictionary())
	if value["reason"] != "not_found" || len(entries(value)) != 0 || !strings.Contains(strings.Join(value["suggestions"].([]string), " "), "translate") {
		t.Fatalf("suggestions = %v", value)
	}
	value = search("bright", "auto", dictionary())
	if len(entries(value)) != 20 || value["truncated"] != true {
		t.Fatalf("bounded results = %v", value)
	}
	if value = search("computer", "zh", dictionary()); value["status"] != "empty" {
		t.Errorf("forced direction = %v", value)
	}
}

func TestInputIsLiteral(t *testing.T) {
	for _, text := range []string{"' OR 1=1 --", "computer%", "computer_", "$(touch /tmp/translate-injection)"} {
		value := search(text, "auto", dictionary())
		if len(entries(value)) != 0 || len(value["suggestions"].([]string)) != 0 {
			t.Errorf("unsafe query %q matched data", text)
		}
	}
}

func TestDatabaseErrors(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing.sqlite3")
	if value := search("hello", "auto", missing); value["reason"] != "dictionary_unavailable" {
		t.Fatalf("missing dictionary = %v", value)
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatalf("created missing dictionary: %v", err)
	}
	if err := os.WriteFile(missing, []byte("corrupt"), 0600); err != nil {
		t.Fatal(err)
	}
	if value := search("hello", "auto", missing); value["reason"] != "dictionary_unavailable" {
		t.Fatalf("corrupt dictionary = %v", value)
	}
}

func TestDirectionRejectsNull(t *testing.T) {
	value := query([]byte(`{"text":"computer","direction":null}`), dictionary())
	if value["reason"] != "invalid_direction" {
		t.Fatalf("direction validation = %v", value)
	}
}
