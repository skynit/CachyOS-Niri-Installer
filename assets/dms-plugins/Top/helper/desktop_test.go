package main

import (
	"strings"
	"testing"
)

func TestParseDesktopEntry(t *testing.T) {
	data := `[Desktop Entry]
Name=Firefox
Name[zh_CN]=火狐
Icon=firefox
Exec=/usr/lib/firefox/firefox %u
StartupWMClass=firefox
NoDisplay=false

[Desktop Action new-window]
Name=New Window
Exec=/usr/lib/firefox/firefox --new-window
`
	entry, exec, wmClass, noDisplay := parseDesktopEntry(data)
	if entry.name != "火狐" || entry.icon != "firefox" {
		t.Errorf("entry = %+v", entry)
	}
	if exec != "/usr/lib/firefox/firefox %u" || wmClass != "firefox" {
		t.Errorf("exec=%q wmClass=%q", exec, wmClass)
	}
	if noDisplay {
		t.Error("NoDisplay should be false")
	}
}

func TestParseDesktopEntryNoDisplay(t *testing.T) {
	data := "[Desktop Entry]\nType=Application\nName=Hidden Tool\nExec=/usr/bin/hidden\nNoDisplay=true\n"
	entry, _, _, noDisplay := parseDesktopEntry(data)
	if entry.name != "Hidden Tool" || !noDisplay {
		t.Errorf("entry=%+v noDisplay=%v", entry, noDisplay)
	}
}

func TestParseDesktopEntryIgnoresOtherSections(t *testing.T) {
	data := "[Desktop Action foo]\nName=Ignore Me\nIcon=ignored\n\n[Desktop Entry]\nName=Keep Me\nIcon=keep\nExec=keep\n"
	entry, _, _, _ := parseDesktopEntry(data)
	if entry.name != "Keep Me" || entry.icon != "keep" {
		t.Errorf("entry = %+v", entry)
	}
}

func TestDesktopIndexLookup(t *testing.T) {
	idx := &desktopIndex{byKey: map[string]appEntry{}}
	data := "[Desktop Entry]\nName=Files\nIcon=system-file-manager\nExec=nautilus %U\nStartupWMClass=org.gnome.Nautilus\n"
	entry, exec, wmClass, _ := parseDesktopEntry(data)
	base, appID := splitExec(exec)
	for _, key := range []string{base, appID, wmClass} {
		if key != "" {
			idx.byKey[strings.ToLower(key)] = entry
		}
	}
	if got, ok := idx.lookup("nautilus", "nautilus"); !ok || got.name != "Files" {
		t.Errorf("lookup by exe = %+v ok=%v", got, ok)
	}
	if got, ok := idx.lookup("", "org.gnome.Nautilus"); !ok || got.icon != "system-file-manager" {
		t.Errorf("lookup by WM class = %+v ok=%v", got, ok)
	}
	if _, ok := idx.lookup("unknown", "unknown"); ok {
		t.Error("unknown process should not resolve")
	}
}
