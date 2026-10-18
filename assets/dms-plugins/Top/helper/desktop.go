package main

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

type appEntry struct {
	name string
	icon string
}

type desktopIndex struct {
	byKey map[string]appEntry
}

// loadDesktopIndex maps executable names and window classes to application
// names and icon names. It is built once at startup.
func loadDesktopIndex() *desktopIndex {
	idx := &desktopIndex{byKey: make(map[string]appEntry)}
	home, _ := os.UserHomeDir()
	dirs := []string{
		"/usr/share/applications",
		"/usr/local/share/applications",
		"/var/lib/flatpak/exports/share/applications",
		filepath.Join(home, ".local/share/applications"),
		filepath.Join(home, ".local/share/flatpak/exports/share/applications"),
	}
	for _, dir := range dirs {
		files, err := filepath.Glob(filepath.Join(dir, "*.desktop"))
		if err != nil {
			continue
		}
		for _, file := range files {
			data, err := os.ReadFile(file)
			if err != nil {
				continue
			}
			entry, exec, wmClass, noDisplay := parseDesktopEntry(string(data))
			if entry.name == "" || noDisplay {
				continue
			}
			keys := make([]string, 0, 4)
			base, appID := splitExec(exec)
			if base != "" {
				keys = append(keys, base)
			}
			if appID != "" {
				keys = append(keys, appID)
			}
			if wmClass != "" {
				keys = append(keys, strings.ToLower(wmClass))
			}
			id := strings.TrimSuffix(filepath.Base(file), ".desktop")
			keys = append(keys, id)
			for _, key := range keys {
				key = strings.ToLower(strings.TrimSpace(key))
				if key == "" {
					continue
				}
				if _, exists := idx.byKey[key]; !exists {
					idx.byKey[key] = entry
				}
			}
		}
	}
	return idx
}

func (d *desktopIndex) lookup(exe, comm string) (appEntry, bool) {
	if d == nil {
		return appEntry{}, false
	}
	candidates := []string{}
	if exe != "" {
		candidates = append(candidates, exe)
	}
	if comm != "" {
		candidates = append(candidates, comm)
	}
	for _, c := range candidates {
		key := strings.ToLower(strings.TrimSpace(c))
		if entry, ok := d.byKey[key]; ok {
			return entry, true
		}
	}
	return appEntry{}, false
}

// parseDesktopEntry reads the [Desktop Entry] group only.
func parseDesktopEntry(s string) (entry appEntry, exec, wmClass string, noDisplay bool) {
	sc := bufio.NewScanner(strings.NewReader(s))
	inSection := false
	var nameZh, nameDefault string
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			inSection = line == "[Desktop Entry]"
			continue
		}
		if !inSection {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		switch key {
		case "Name":
			nameDefault = value
		case "Name[zh_CN]":
			nameZh = value
		case "Icon":
			entry.icon = value
		case "Exec":
			exec = value
		case "StartupWMClass":
			wmClass = value
		case "NoDisplay":
			noDisplay = strings.EqualFold(value, "true")
		}
	}
	entry.name = nameDefault
	if nameZh != "" {
		entry.name = nameZh
	}
	if entry.icon == "" {
		entry.icon = "application-x-executable"
	}
	return entry, exec, wmClass, noDisplay
}
