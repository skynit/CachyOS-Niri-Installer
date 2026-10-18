package main

import (
	"database/sql"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

func TestTimestampsAndTranslations(t *testing.T) {
	value, err := parse("[01:02.345]third\n[00:00.2]first\n[00:03:45]second")
	if err != nil || value.Status != "synced" || len(value.Lines) != 3 || *value.Lines[0].Time != .2 || *value.Lines[1].Time != 3.45 || *value.Lines[2].Time != 62.345 {
		t.Fatalf("stamps = %#v, %v", value, err)
	}
	value, err = parse("[00:01][00:05]first\n[00:01]译文\n[00:01]first")
	if err != nil || len(value.Lines) != 2 || value.Lines[0].Text != "first\n译文" || value.Lines[1].Text != "first" {
		t.Fatalf("multiple stamps = %#v, %v", value, err)
	}
	value, err = parse("[00:01]first\n[offset:+1500]")
	if err != nil || *value.Lines[0].Time != -.5 {
		t.Fatalf("offset = %#v, %v", value, err)
	}
	value, err = parse("[00:01]first\n[00:02]")
	if err != nil || value.Lines[1].Text != "" {
		t.Fatalf("empty timed line = %#v, %v", value, err)
	}
	value, err = parse("[ar:Artist]\n[00:01]<00:01.10>hello <00:01.5>world")
	if err != nil || value.Lines[0].Text != "hello world" {
		t.Fatalf("word stamps = %#v, %v", value, err)
	}
}

func TestPlainAndLimits(t *testing.T) {
	value, _ := parse("[ar:Artist]\nplain text")
	if value.Status != "plain" || !reflect.DeepEqual(value.Lines, []line{{Text: "plain text"}}) {
		t.Fatalf("plain = %#v", value)
	}
	value, _ = parse("[ar:Artist]\n")
	if value.Status != "empty" || len(value.Lines) != 0 {
		t.Fatalf("empty = %#v", value)
	}
	var lines strings.Builder
	for i := 0; i <= maxLines; i++ {
		lines.WriteString("[00:01]line\n")
	}
	if _, err := parse(lines.String()); err != nil {
		// Duplicate timestamps are one line, so no error is expected.
		t.Errorf("counted duplicate timestamps: %v", err)
	}
	lines.Reset()
	for i := 0; i <= maxLines; i++ {
		lines.WriteString("plain\n")
	}
	if _, err := parse(lines.String()); err == nil {
		t.Fatal("accepted too many plain lines")
	}
}

func sample(t *testing.T, extension, codec, lyrics string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "embedded."+extension)
	args := []string{"-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono", "-t", "0.1", "-c:a", codec}
	if lyrics != "" {
		args = append(args, "-metadata", "lyrics="+lyrics)
	}
	args = append(args, path)
	if output, err := exec.Command("ffmpeg", args...).CombinedOutput(); err != nil {
		t.Fatalf("generate %s: %v: %s", extension, err, output)
	}
	return path
}

func TestRealEmbeddedFormats(t *testing.T) {
	for _, spec := range []struct{ extension, codec string }{
		{"flac", "flac"}, {"mp3", "libmp3lame"}, {"m4a", "aac"}, {"ogg", "libvorbis"},
	} {
		t.Run(spec.extension, func(t *testing.T) {
			path := sample(t, spec.extension, spec.codec, "[00:01.00]第一句测试\n[00:03.50]第二句测试")
			value := load(request{URL: (&url.URL{Scheme: "file", Path: path}).String()})
			if value.Status != "synced" || len(value.Lines) != 2 || *value.Lines[1].Time != 3.5 || value.Source != "embedded" {
				t.Fatalf("lyrics = %#v", value)
			}
		})
	}
}

func TestPlainMissingAndRemote(t *testing.T) {
	plain := sample(t, "flac", "flac", "纯文本内嵌歌词测试")
	if value := load(request{URL: (&url.URL{Scheme: "file", Path: plain}).String()}); value.Status != "plain" {
		t.Fatalf("plain = %#v", value)
	}
	missing := sample(t, "flac", "flac", "")
	if value := load(request{URL: (&url.URL{Scheme: "file", Path: missing}).String()}); value.Reason != "no_embedded_lyrics" {
		t.Fatalf("no lyrics = %#v", value)
	}
	if value := load(request{URL: "https://example.com/song.mp3", Title: "song"}); value.Status != "error" {
		t.Fatalf("remote URL accepted: %#v", value)
	}
	if value := load(request{}); value.Reason != "no_track" {
		t.Fatalf("missing track = %#v", value)
	}
}

func TestTermusicLibrary(t *testing.T) {
	folder := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", folder)
	lib := filepath.Join(folder, "termusic")
	if err := os.MkdirAll(lib, 0700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", filepath.Join(lib, "library2.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, query := range []string{
		"CREATE TABLE tracks (id INTEGER, file_dir TEXT, file_stem TEXT, file_ext TEXT, duration REAL, album INTEGER)",
		"CREATE TABLE tracks_metadata (track INTEGER, title TEXT, artist_display TEXT)",
		"CREATE TABLE albums (id INTEGER, title TEXT)",
		"INSERT INTO albums VALUES (1, 'Demo')",
		"INSERT INTO tracks VALUES (1, '/music', 'first', 'flac', 64, 1)",
		"INSERT INTO tracks VALUES (2, '/music', 'second', 'flac', 95, 1)",
		"INSERT INTO tracks_metadata VALUES (1, 'Song', 'Artist')",
		"INSERT INTO tracks_metadata VALUES (2, 'Song', 'Artist')",
	} {
		if _, err := db.Exec(query); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := songPath(request{Player: "termusic", Title: "Song", Artist: "Artist"}); err == nil || !strings.Contains(err.Error(), "多个") {
		t.Errorf("accepted ambiguous track: %v", err)
	}
	path, err := songPath(request{Player: "termusic", Title: "Song", Artist: "Artist", Duration: 65})
	if err != nil || path != "/music/first.flac" {
		t.Fatalf("duration selection = %q, %v", path, err)
	}
	if _, err := songPath(request{Player: "termusic", Title: "Song' OR 1=1 --", Artist: "Artist"}); err == nil {
		t.Fatal("SQL text changed query semantics")
	}
}
