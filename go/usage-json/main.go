package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

const maxRecord = 16 * 1024 * 1024

func record(input []byte) (json.RawMessage, error) {
	var value json.RawMessage
	if len(input) > maxRecord || json.Unmarshal(input, &value) != nil {
		return nil, errors.New("采集器输出的不是合法 JSON")
	}
	if string(value) == "null" || string(value) == "false" {
		return nil, errors.New("采集器输出的不是合法 JSON")
	}
	return value, nil
}

func read(dir string) []json.RawMessage {
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return []json.RawMessage{}
	}
	values := make([]json.RawMessage, 0, len(files))
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			return []json.RawMessage{}
		}
		value, err := record(data)
		if err != nil {
			return []json.RawMessage{}
		}
		values = append(values, value)
	}
	return values
}

func combine(oldData, newData json.RawMessage) (json.RawMessage, error) {
	var oldValue, newValue map[string]json.RawMessage
	if json.Unmarshal(oldData, &oldValue) != nil || json.Unmarshal(newData, &newValue) != nil || oldValue == nil || newValue == nil {
		return newData, nil
	}
	for key, value := range newValue {
		var err error
		oldValue[key], err = combine(oldValue[key], value)
		if err != nil {
			return nil, err
		}
	}
	return json.Marshal(oldValue)
}

func merged(oldData, newData []byte) ([]byte, error) {
	var oldValue, newValue map[string]json.RawMessage
	if json.Unmarshal(oldData, &oldValue) != nil || json.Unmarshal(newData, &newValue) != nil || oldValue == nil || newValue == nil {
		return nil, errors.New("无法合并用量记录")
	}
	for _, key := range []string{"limits", "usageStatusText", "tierLabel", "updatedAt"} {
		replacement, ok := newValue[key]
		if !ok {
			replacement = json.RawMessage("null")
		}
		if key == "limits" {
			var err error
			replacement, err = combine(oldValue[key], replacement)
			if err != nil {
				return nil, err
			}
		}
		oldValue[key] = replacement
	}
	return json.Marshal(oldValue)
}

func run(args []string, input io.Reader) (any, error) {
	if len(args) == 2 && args[0] == "read" {
		return read(args[1]), nil
	}
	if len(args) == 1 && args[0] == "check" {
		data, err := io.ReadAll(io.LimitReader(input, maxRecord+1))
		if err != nil {
			return nil, err
		}
		_, err = record(data)
		return map[string]bool{"ok": true}, err
	}
	if len(args) == 2 && args[0] == "merge" {
		oldData, err := os.ReadFile(args[1])
		if err != nil {
			return nil, err
		}
		newData, err := io.ReadAll(io.LimitReader(input, maxRecord+1))
		if err != nil {
			return nil, err
		}
		return merged(oldData, newData)
	}
	return nil, errors.New("Usage: cachyos-usage-json read DIR | check | merge OLD_FILE")
}

func main() {
	value, err := run(os.Args[1:], os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if bytes, ok := value.([]byte); ok {
		fmt.Println(string(bytes))
		return
	}
	if err := json.NewEncoder(os.Stdout).Encode(value); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
