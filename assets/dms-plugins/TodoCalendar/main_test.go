package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"
)

var recordIDs atomic.Int64

func draft() Note {
	return Note{ID: fmt.Sprintf("00000000-0000-4000-8000-%012d", recordIDs.Add(1)), Title: "工作记录", Body: "前言\n- [ ] 第一项\r\n  * [X] 第二项\n", Date: str("2026-10-29"), Status: "active", Tags: []string{"工作"}}
}

func str(s string) *string { return &s }

func call(t *testing.T, dir string, req Request) Response {
	t.Helper()
	if req.Month == "" {
		req.Month = "2026-10"
	}
	return handle(dir, req)
}

func save(t *testing.T, dir string, note Note) Note {
	t.Helper()
	got := call(t, dir, Request{Action: "save", Note: &note})
	if !got.OK {
		t.Fatalf("save: %+v", got)
	}
	return *got.Data.Note
}

func TestSaveReadConflictAndDelete(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	n := save(t, dir, draft())
	if n.ID == "" || n.Revision != 1 || n.Created == 0 {
		t.Fatalf("created: %+v", n)
	}
	n.Title = "新标题"
	next := save(t, dir, n)
	if next.Revision != 2 || next.Created != n.Created {
		t.Fatalf("updated: %+v", next)
	}
	conflict := call(t, dir, Request{Action: "save", Note: &n})
	if conflict.OK || conflict.Reason != "revision_conflict" {
		t.Fatalf("conflict: %+v", conflict)
	}
	bad := call(t, dir, Request{Action: "delete", ID: n.ID, Revision: 1})
	if bad.OK {
		t.Fatal("stale delete accepted")
	}
	got := call(t, dir, Request{Action: "get", ID: n.ID})
	if !got.OK || got.Data.Note.Title != "新标题" {
		t.Fatalf("get: %+v", got)
	}
	deleted := call(t, dir, Request{Action: "delete", ID: n.ID, Revision: 2})
	if !deleted.OK || len(deleted.Data.Notes) != 0 {
		t.Fatalf("delete: %+v", deleted)
	}
	if call(t, dir, Request{Action: "get", ID: n.ID}).OK {
		t.Fatal("deleted record still available")
	}
	info, err := os.Stat(filepath.Join(dir, "notes.json"))
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("private storage: %v, %v", info, err)
	}
}

func TestSnapshotIncludesWholeGridAndUndated(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	for _, day := range []string{"2026-09-28", "2026-10-29", "2026-11-08", "2026-11-09", ""} {
		n := draft()
		n.Date = nil
		if day != "" {
			n.Date = str(day)
		}
		save(t, dir, n)
	}
	got := call(t, dir, Request{Action: "snapshot"})
	if !got.OK || len(got.Data.Notes) != 4 {
		t.Fatalf("grid: %+v", got)
	}
	for _, n := range got.Data.Notes {
		if n.Date != nil && *n.Date == "2026-11-09" {
			t.Fatal("outside grid included")
		}
	}
}

func TestChecklistPreservesBodyAndIgnoresCode(t *testing.T) {
	body := "前言\r\n- [ ] 第一项\r\n```md\n- [ ] 代码示例\n```\n  + [X] 第二项\n"
	items := checklist(body)
	if len(items) != 2 || items[0].Checked || !items[1].Checked {
		t.Fatalf("items: %+v", items)
	}
	got, err := toggle(body, 0, true)
	if err != nil || got != strings.Replace(body, "- [ ] 第一项", "- [x] 第一项", 1) {
		t.Fatalf("toggle: %q, %v", got, err)
	}
	if _, err = toggle(body, 2, true); err == nil {
		t.Fatal("invalid index accepted")
	}
}

func TestImportIsAtomicAndNeverOverwrites(t *testing.T) {
	dir, input := filepath.Join(t.TempDir(), "state"), filepath.Join(t.TempDir(), "export.json")
	n := draft()
	n.ID = "018f5f7b-f2fa-7ca2-a4f0-0bb7588cc203"
	n.Revision = 7
	n.Created = 1
	n.Updated = 2
	write := func(notes []Note) {
		t.Helper()
		b, err := json.Marshal(struct {
			Schema string `json:"schema"`
			Notes  []Note `json:"notes"`
		}{"localdesk.notes.export.v1", notes})
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(input, b, 0600); err != nil {
			t.Fatal(err)
		}
	}
	write([]Note{n})
	first := call(t, dir, Request{Action: "import", Path: input})
	if !first.OK || first.Data.Imported != 1 {
		t.Fatalf("first: %+v", first)
	}
	again := call(t, dir, Request{Action: "import", Path: input})
	if !again.OK || again.Data.Skipped != 1 {
		t.Fatalf("again: %+v", again)
	}
	n.Title = "其他来源的修改"
	other := n
	other.ID = "018f5f7b-f2fa-7ca2-a4f0-0bb7588cc204"
	write([]Note{n, other})
	conflict := call(t, dir, Request{Action: "import", Path: input})
	if conflict.OK || conflict.Reason != "import_conflict" {
		t.Fatalf("conflict: %+v", conflict)
	}
	state := call(t, dir, Request{Action: "snapshot"})
	if len(state.Data.Notes) != 1 || state.Data.Notes[0].Title != "工作记录" {
		t.Fatalf("atomic import: %+v", state)
	}
}

func TestInvalidInputDoesNotCreateOrEraseRecords(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*Note)
	}{
		{"date", func(n *Note) { n.Date = str("2026-02-30") }},
		{"status", func(n *Note) { n.Status = "unknown" }},
		{"title", func(n *Note) { n.Title = strings.Repeat("长", 513) }},
		{"body", func(n *Note) { n.Body = strings.Repeat("x", 4*1024*1024+1) }},
		{"tags", func(n *Note) { n.Tags = []string{strings.Repeat("长", 65)} }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "state")
			n := draft()
			tc.change(&n)
			if got := call(t, dir, Request{Action: "save", Note: &n}); got.OK {
				t.Fatalf("accepted: %+v", got)
			}
		})
	}
	dir := filepath.Join(t.TempDir(), "state")
	save(t, dir, draft())
	path := filepath.Join(dir, "notes.json")
	if err := os.WriteFile(path, []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := call(t, dir, Request{Action: "save", Note: ptrNote(draft())}); got.OK {
		t.Fatal("corrupt storage overwritten")
	}
	bytes, err := os.ReadFile(path)
	if err != nil || string(bytes) != "broken" {
		t.Fatal("corrupt storage was changed")
	}
}

func ptrNote(n Note) *Note { return &n }

func TestSymlinkStorageIsRejected(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(t.TempDir(), "outside.json")
	if err := os.WriteFile(outside, []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, "notes.json")); err != nil {
		t.Fatal(err)
	}
	if got := call(t, dir, Request{Action: "snapshot"}); got.OK {
		t.Fatal("symlink accepted")
	}
}

func TestConcurrentSaveAcceptsOnlyOneVersion(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	n := save(t, dir, draft())
	var group sync.WaitGroup
	results := make(chan Response, 8)
	for i := 0; i < 8; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			results <- handle(dir, Request{Action: "save", Month: "2026-10", Note: &n})
		}()
	}
	group.Wait()
	close(results)
	accepted := 0
	for result := range results {
		if result.OK {
			accepted++
		} else if result.Reason != "revision_conflict" {
			t.Fatalf("unexpected failure: %+v", result)
		}
	}
	if accepted != 1 {
		t.Fatalf("accepted %d stale writes", accepted)
	}
}

func TestSQLiteImportReadsWithoutChangingSource(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notes.sqlite3")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.Exec(`PRAGMA user_version=3;
	 CREATE TABLE notes(id TEXT,title TEXT,body_markdown TEXT,diary_date TEXT,status TEXT,pinned INTEGER,created_at_ms INTEGER,updated_at_ms INTEGER,deleted_at_ms INTEGER,revision INTEGER);
	 CREATE TABLE note_tags(note_id TEXT,tag_key TEXT,display_tag TEXT);
	 INSERT INTO notes VALUES('018f5f7b-f2fa-7ca2-a4f0-0bb7588cc203','原记录','- [ ] 待办','2026-10-29','completed',1,1,2,NULL,7);
	 INSERT INTO note_tags VALUES('018f5f7b-f2fa-7ca2-a4f0-0bb7588cc203','工作','工作');`)
	if err != nil {
		t.Fatal(err)
	}
	if err = db.Close(); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	got := call(t, filepath.Join(t.TempDir(), "state"), Request{Action: "import", Path: path})
	if !got.OK || got.Data.Imported != 1 {
		t.Fatalf("import: %+v", got)
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("source database was modified")
	}
	notes, err := readImport(path)
	if err != nil || len(notes) != 1 || notes[0].Tags[0] != "工作" || !notes[0].Pinned || notes[0].Revision != 7 {
		t.Fatalf("fields lost: %+v, %v", notes, err)
	}
	db, err = sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("PRAGMA user_version=99"); err != nil {
		t.Fatal(err)
	}
	if err = db.Close(); err != nil {
		t.Fatal(err)
	}
	if got = call(t, filepath.Join(t.TempDir(), "state"), Request{Action: "import", Path: path}); got.OK || got.Reason != "import_schema_unsupported" {
		t.Fatalf("unknown schema accepted: %+v", got)
	}
}

func TestProtocolRejectsTrailingAndUnknownInput(t *testing.T) {
	for _, input := range []string{`{"action":"snapshot"} {}`, `{"action":"snapshot","shell":"echo"}`, `{"action":`, strings.Repeat(" ", 128) + `{}`} {
		var req Request
		if err := decode(strings.NewReader(input), 64, &req); err == nil {
			t.Fatalf("accepted %q", input)
		}
	}
}

func TestCreationRetryDoesNotDuplicateOrOverwrite(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	n := draft()
	first := save(t, dir, n)
	retried := save(t, dir, n)
	if first.ID != retried.ID || retried.Revision != 1 {
		t.Fatalf("retry created new record: %+v", retried)
	}
	if got := call(t, dir, Request{Action: "snapshot"}); len(got.Data.Notes) != 1 {
		t.Fatal("duplicate creation")
	}
	n.Title = "重试时已改变内容"
	if got := call(t, dir, Request{Action: "save", Note: &n}); got.OK || got.Reason != "revision_conflict" {
		t.Fatalf("retry overwrote content: %+v", got)
	}
}

func TestFutureTimestampsAndVersionLimitCannotCorruptStorage(t *testing.T) {
	for _, action := range []string{"save", "delete"} {
		t.Run(action, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "state")
			n := draft()
			n.Revision = 1
			n.Created = time.Now().Add(24 * time.Hour).UnixMilli()
			n.Updated = n.Created
			writeStore := func() {
				t.Helper()
				if err := os.MkdirAll(dir, 0700); err != nil {
					t.Fatal(err)
				}
				b, err := json.Marshal(disk{Schema: schema, Notes: []Note{n}})
				if err != nil {
					t.Fatal(err)
				}
				if err = os.WriteFile(filepath.Join(dir, "notes.json"), b, 0600); err != nil {
					t.Fatal(err)
				}
			}
			writeStore()
			got := call(t, dir, Request{Action: action, ID: n.ID, Revision: n.Revision, Note: &n})
			if !got.OK {
				t.Fatalf("future timestamp: %+v", got)
			}
			if got = call(t, dir, Request{Action: "snapshot"}); !got.OK {
				t.Fatalf("storage corrupted: %+v", got)
			}
			n.Revision = (1 << 53) - 1
			writeStore()
			got = call(t, dir, Request{Action: action, ID: n.ID, Revision: n.Revision, Note: &n})
			if got.OK || got.Reason != "revision_exhausted" {
				t.Fatalf("version overflow: %+v", got)
			}
			if got = call(t, dir, Request{Action: "snapshot"}); !got.OK {
				t.Fatalf("overflow corrupted storage: %+v", got)
			}
		})
	}
}

func TestImportRejectsFIFOWithoutBlockingStorage(t *testing.T) {
	fifo := filepath.Join(t.TempDir(), "fifo")
	if err := syscall.Mkfifo(fifo, 0600); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(t.TempDir(), "state")
	start := time.Now()
	if got := call(t, dir, Request{Action: "import", Path: fifo}); got.OK || got.Reason != "import_invalid" {
		t.Fatalf("fifo accepted: %+v", got)
	}
	if time.Since(start) > time.Second {
		t.Fatal("fifo blocked the importer")
	}
	if got := call(t, dir, Request{Action: "snapshot"}); !got.OK {
		t.Fatalf("storage blocked: %+v", got)
	}
}

func TestInstallRejectsLinkedManifest(t *testing.T) {
	base := t.TempDir()
	source := filepath.Join(base, "source")
	if err := os.Mkdir(source, 0700); err != nil {
		t.Fatal(err)
	}
	script, err := os.ReadFile("install.sh")
	if err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{"install.sh": string(script), "plugin.json": `{"id":"todoCalendar","version":"1.0.0","components":{"widget":"./CalendarWindow.qml","daemon":"./CalendarWindow.qml"}}`, "Calendar.js": "old", "CalendarWindow.qml": "old", "todo-calendar-helper": "#!/bin/sh\nexit 0\n"} {
		if err = os.WriteFile(filepath.Join(source, name), []byte(body), 0700); err != nil {
			t.Fatal(err)
		}
	}
	config := filepath.Join(base, "config")
	run := func() error {
		cmd := exec.Command("bash", filepath.Join(source, "install.sh"))
		cmd.Env = append(os.Environ(), "XDG_CONFIG_HOME="+config)
		_, err := cmd.CombinedOutput()
		return err
	}
	if err = run(); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(config, "DankMaterialShell", "plugins", "TodoCalendar")
	manifest := filepath.Join(target, ".installed-files.sha256")
	original, err := os.ReadFile(manifest)
	if err != nil {
		t.Fatal(err)
	}
	installedManifest, readErr := os.ReadFile(filepath.Join(target, "plugin.json"))
	if readErr != nil {
		t.Fatal(readErr)
	}
	var before struct {
		Components map[string]string `json:"components"`
	}
	if json.Unmarshal(installedManifest, &before) != nil {
		t.Fatal("invalid installed plugin manifest")
	}
	if _, statErr := os.Stat(filepath.Join(target, before.Components["widget"])); statErr != nil {
		t.Fatalf("runtime entry missing: %v", statErr)
	}

	outside := filepath.Join(base, "external-checksums")
	if err = os.WriteFile(outside, original, 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.Remove(manifest); err != nil {
		t.Fatal(err)
	}
	if err = os.Symlink(outside, manifest); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(source, "plugin.json"), []byte("new"), 0600); err != nil {
		t.Fatal(err)
	}
	if err = run(); err == nil {
		t.Fatal("installer accepted a linked checksum manifest")
	}
	after, err := os.ReadFile(outside)
	if err != nil || !bytes.Equal(original, after) {
		t.Fatal("external manifest was modified")
	}
	plugin, err := os.ReadFile(filepath.Join(target, "plugin.json"))
	var installed struct {
		Version    string            `json:"version"`
		Components map[string]string `json:"components"`
	}
	parseErr := json.Unmarshal(plugin, &installed)
	if err != nil || parseErr != nil || installed.Version != "1.0.0" || !strings.HasPrefix(installed.Components["widget"], ".runtime-") {
		t.Fatal("old installation changed after rejection")
	}
}

func TestJournalWindowAndText(t *testing.T) {
	_, start, end, err := journalWindow("2026-03-08", "America/New_York")
	if err != nil || end.Sub(start) != 23*time.Hour {
		t.Fatalf("DST: %v %v", end.Sub(start), err)
	}
	if _, _, _, err = journalWindow("2026-02-30", "Asia/Shanghai"); err == nil {
		t.Fatal("invalid date accepted")
	}
	s := Session{Messages: []Message{}}
	addMessage(&s, "user", "# AGENTS.md instructions\nignore these")
	addMessage(&s, "assistant", "修复完成\nAuthorization: secret")
	addMessage(&s, "assistant", "修复完成\nAuthorization: secret")
	finishSession(&s)
	if len(s.Messages) != 1 || strings.Contains(s.Messages[0].Content, "secret") || s.Eligibility.State != "ignored_short" {
		t.Fatalf("sanitize: %+v", s)
	}
	addMessage(&s, "user", strings.Repeat("中", 1200))
	finishSession(&s)
	if s.Eligibility.State != "included" {
		t.Fatal("character threshold ignored")
	}
}

func TestJournalCorpusLimitsReportActualInput(t *testing.T) {
	scanned, included, ignored := 20, 20, 0
	c := &Corpus{Coverage: []Coverage{{Source: "codex", State: "healthy", Scanned: &scanned, Included: &included, Ignored: &ignored}}, Warnings: []string{}}
	for i := 0; i < 20; i++ {
		session := Session{Source: "codex", ID: fmt.Sprint(i)}
		for j := 0; j < 4; j++ {
			addMessage(&session, "user", strings.Repeat(string(rune('a'+j)), 16000))
		}
		finishSession(&session)
		c.Sessions = append(c.Sessions, session)
	}
	limitCorpus(c)
	actual := 0
	chars := 0
	for _, session := range c.Sessions {
		if session.Eligibility.State == "included" {
			actual++
		}
		for _, message := range session.Messages {
			chars += len([]rune(message.Content))
		}
	}
	if actual != *c.Coverage[0].Included || chars != 1000000 || c.Coverage[0].State != "degraded" || len(c.Warnings) != 1 {
		t.Fatalf("limits: chars=%d actual=%d coverage=%+v warnings=%v", chars, actual, c.Coverage, c.Warnings)
	}
}

func TestJournalCollectionAndCache(t *testing.T) {
	home := t.TempDir()
	date, zone := "2026-10-29", "Asia/Shanghai"
	_, start, _, _ := journalWindow(date, zone)
	stamp := start.Add(time.Hour).UnixMilli()
	path := filepath.Join(home, ".codex", "sessions", "test.jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	lines := `{"type":"session_meta","payload":{"id":"session-a","cwd":"/work"}}` + "\n"
	for i := 0; i < 4; i++ {
		lines += fmt.Sprintf(`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"工作证据 %d"}]}}`, i) + "\n"
	}
	if err := os.WriteFile(path, []byte(lines), 0600); err != nil {
		t.Fatal(err)
	}
	dbpath := filepath.Join(home, ".cc-switch", "cc-switch.db")
	if err := os.MkdirAll(filepath.Dir(dbpath), 0700); err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("sqlite", dbpath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, query := range []string{`CREATE TABLE providers(app_type TEXT)`, `INSERT INTO providers VALUES ('codex'),('claude')`, `CREATE TABLE session_log_sync(file_path TEXT,last_modified INTEGER,last_synced_at INTEGER)`, `CREATE TABLE proxy_request_logs(app_type TEXT,created_at INTEGER,input_tokens INTEGER,output_tokens INTEGER,cache_read_tokens INTEGER,cache_creation_tokens INTEGER,input_token_semantics TEXT)`} {
		if _, err = db.Exec(query); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = db.Exec(`INSERT INTO session_log_sync VALUES (?,?,?)`, path, stamp, stamp/1000); err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(`INSERT INTO proxy_request_logs VALUES ('codex',?,10,4,2,0,'reported')`, stamp/1000); err != nil {
		t.Fatal(err)
	}
	c, err := collectJournal(context.Background(), home, date, zone)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Sessions) != 1 || c.Sessions[0].ID != "session-a" || c.Coverage[0].Included == nil || *c.Coverage[0].Included != 1 {
		t.Fatalf("collection: %+v", c)
	}
	if c.Coverage[1].Reason != "cc_switch_session_source_not_tracked" || c.Coverage[2].State != "unsupported" {
		t.Fatalf("coverage: %+v", c.Coverage)
	}
	if c.Usage["input_tokens"] != int64(10) {
		t.Fatalf("usage: %+v", c.Usage)
	}
	entry := Journal{Collection: c, Updated: stamp}
	dir := filepath.Join(t.TempDir(), "state")
	if err = writeJournal(dir, date, zone, &entry); err != nil {
		t.Fatal(err)
	}
	got, err := readJournal(dir, date, zone)
	if err != nil || got == nil || got.Collection.Sessions[0].ID != "session-a" {
		t.Fatalf("cache: %+v %v", got, err)
	}
	if len(got.Collection.Sessions[0].Messages) != 0 {
		t.Fatal("raw session text persisted")
	}
	summary := &JournalSummary{Schema: 1, Date: date, Timezone: zone, Title: "上次总结", Body: "上次总结正文", Coverage: c.Coverage, Usage: c.Usage, Work: []WorkItem{}, Knowledge: []KnowledgeItem{}, Candidates: []Candidate{}, Remaining: []string{}, Warnings: []string{}}
	entry.Summary = summary
	entry.SummaryCollection = c
	entry.SummaryUpdated = stamp
	if err = writeJournal(dir, date, zone, &entry); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	collected, err := journalRequest(context.Background(), dir, Request{Action: "journal_collect", Date: date, Timezone: zone})
	if err != nil || collected.Journal.Summary == nil || collected.Journal.Summary.Body != "上次总结正文" {
		t.Fatalf("collect destroyed summary: %+v %v", collected, err)
	}
	cached, err := readJournal(dir, date, zone)
	if err != nil || cached.SummaryCollection == nil || len(cached.SummaryCollection.Sessions[0].Messages) != 0 {
		t.Fatalf("summary snapshot: %+v %v", cached, err)
	}

	if err = os.Symlink(path, filepath.Join(home, ".codex", "sessions", "link.jsonl")); err != nil {
		t.Fatal(err)
	}
	if _, err = parseSession(context.Background(), home, "codex", filepath.Join(home, ".codex", "sessions", "link.jsonl"), stamp); err == nil {
		t.Fatal("symlink accepted")
	}
}

func TestJournalSummaryFactsAndReferences(t *testing.T) {
	c := &Corpus{Schema: 1, Date: "2026-10-29", Timezone: "Asia/Shanghai", Coverage: []Coverage{}, Usage: map[string]any{"input_tokens": nil}, Warnings: []string{}, Sessions: []Session{{ID: "a", Eligibility: Eligibility{State: "included", Length: "normal"}}}}
	s := &JournalSummary{Schema: 1, Date: c.Date, Timezone: c.Timezone, Title: "工作日志", Body: "# 日志\n\n## 今日工作\n已检查。", Coverage: c.Coverage, Usage: c.Usage, Work: []WorkItem{{Workstream: "插件", State: "in_progress", Summary: "检查接口", Evidence: []string{"会话记录"}, Sessions: []string{"a"}}}, Knowledge: []KnowledgeItem{}, Candidates: []Candidate{}, Remaining: []string{}, Warnings: []string{}}
	if err := validateSummary(s, c); err != nil {
		t.Fatal(err)
	}
	s.Work[0].State = "completed|in_progress"
	if validateSummary(s, c) == nil {
		t.Fatal("non-enum work state accepted")
	}
	s.Work[0].State = "in_progress"

	s.Work[0].Sessions = []string{"missing"}
	if validateSummary(s, c) == nil {
		t.Fatal("unknown session accepted")
	}
	s.Work[0].Sessions = []string{"a"}
	s.Usage = map[string]any{"input_tokens": 0}
	if validateSummary(s, c) == nil {
		t.Fatal("invented token count accepted")
	}
	s.Usage = c.Usage
	s.Candidates = []Candidate{{Session: "a", Recommended: true, Reason: "知识", Skill: "capture-conversations-to-vault"}}
	if validateSummary(s, c) == nil {
		t.Fatal("short knowledge candidate accepted")
	}
}

func TestJournalCodexTransportAndCancellation(t *testing.T) {
	bin := t.TempDir()
	resultPath := filepath.Join(bin, "fixture.json")
	inputPath := filepath.Join(bin, "input.json")
	c := &Corpus{Schema: 1, Date: "2026-10-29", Timezone: "Asia/Shanghai", Coverage: []Coverage{}, Usage: map[string]any{"input_tokens": nil}, Warnings: []string{}, Sessions: []Session{{ID: "a", Eligibility: Eligibility{State: "included", Length: "normal"}, Messages: []Message{{"user", "唯一的语料证据"}}}}}
	s := JournalSummary{Schema: 1, Date: c.Date, Timezone: c.Timezone, Title: "工作日志", Body: "# 工作日志\n\n## Token usage\n不得进入正文\n\n## 今日工作\n核对接口", Coverage: c.Coverage, Usage: c.Usage, Work: []WorkItem{{Workstream: "插件", State: "in_progress", Summary: "核对接口", Evidence: []string{"已阅读"}, Sessions: []string{"a"}}}, Knowledge: []KnowledgeItem{}, Candidates: []Candidate{}, Remaining: []string{}, Warnings: []string{}}
	encoded, _ := json.Marshal(s)
	envelope, _ := json.Marshal(map[string]string{"summary_json": string(encoded)})
	if err := os.WriteFile(resultPath, envelope, 0600); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\ncat > \"$TODO_AI_INPUT\"\nwhile [ \"$#\" -gt 0 ]; do\n if [ \"$1\" = --output-last-message ]; then shift; cp -- \"$TODO_AI_FIXTURE\" \"$1\"; fi\n shift\ndone\n"
	if err := os.WriteFile(filepath.Join(bin, "codex"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	t.Setenv("TODO_AI_INPUT", inputPath)
	t.Setenv("TODO_AI_FIXTURE", resultPath)
	t.Setenv("CODEX_HOME", t.TempDir())
	got, err := runSummary(context.Background(), c)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(got.Body, "不得进入正文") || !strings.Contains(got.Body, "核对接口") {
		t.Fatalf("body: %s", got.Body)
	}
	input, err := os.ReadFile(inputPath)
	if err != nil || !bytes.Contains(input, []byte("唯一的语料证据")) {
		t.Fatal("corpus did not reach codex stdin")
	}
	noisy := script + "head -c 2200000 /dev/zero >&2\nhead -c 2200000 /dev/zero\n"
	if err = os.WriteFile(filepath.Join(bin, "codex"), []byte(noisy), 0700); err != nil {
		t.Fatal(err)
	}
	if _, err = runSummary(context.Background(), c); err != nil {
		t.Fatalf("diagnostic volume interrupted valid summary: %v", err)
	}
	if err = os.WriteFile(filepath.Join(bin, "codex"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}

	s.Body = "## Token usage\n全是用量"
	encoded, _ = json.Marshal(s)
	envelope, _ = json.Marshal(map[string]string{"summary_json": string(encoded)})
	if err = os.WriteFile(resultPath, envelope, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = runSummary(context.Background(), c); err == nil {
		t.Fatal("empty cleaned summary accepted")
	}

	if err = os.WriteFile(filepath.Join(bin, "codex"), []byte("#!/bin/sh\nsleep 30\n"), 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	before := time.Now()
	if _, err = runSummary(ctx, c); !errors.Is(err, context.DeadlineExceeded) || time.Since(before) > 3*time.Second {
		t.Fatalf("cancel: %v %v", err, time.Since(before))
	}
}

func TestJournalCodexDiagnostics(t *testing.T) {
	output := &codexOutput{limit: 128}
	if _, err := io.Copy(output, strings.NewReader(strings.Repeat("x", 2000000)+"TAIL")); err != nil {
		t.Fatal(err)
	}
	if len(output.data) != 128 || !strings.HasSuffix(output.String(), "TAIL") {
		t.Fatal("diagnostic output exceeded bound or lost tail")
	}
	for _, tc := range []struct{ message, reason string }{
		{"context_length_exceeded", "codex_input_too_large"},
		{"Input exceeds the maximum length of 1048576 characters", "codex_input_too_large"},
		{"unexpected status 401 Unauthorized", "codex_auth_failed"},
		{"unexpected status 429 Too Many Requests", "codex_rate_limited"},
		{"unexpected status 502 Bad Gateway", "codex_provider_unavailable"},
		{"stream disconnected before completion", "codex_connection_failed"},
		{"model_not_found", "codex_model_unavailable"},
		{"invalid_json_schema", "codex_schema_rejected"},
	} {
		event, _ := json.Marshal(map[string]any{"type": "turn.failed", "error": map[string]string{"message": tc.message + " Authorization: synthetic-secret"}})
		err := codexFailure(string(event), "", 1)
		var problem *problem
		if !errors.As(err, &problem) || problem.reason != tc.reason || strings.Contains(problem.message, "synthetic-secret") {
			t.Fatalf("unsafe or incorrect error: %+v", err)
		}
	}
}

func TestJournalPromptBudgetIncludesEscapingAndRules(t *testing.T) {
	c := &Corpus{Schema: 1, Date: "2026-10-29", Timezone: "Asia/Shanghai", Coverage: []Coverage{}, Usage: map[string]any{"input_tokens": nil}, Sessions: []Session{}, Warnings: []string{}}
	scanned, included, ignored := 24, 24, 0
	c.Coverage = []Coverage{{Source: "codex", State: "healthy", Reason: "session_source_ready", Scanned: &scanned, Included: &included, Ignored: &ignored}}
	for i := 0; i < 24; i++ {
		s := Session{Source: "codex", ID: fmt.Sprint(i), Title: "会话"}
		for n := 0; n < 4; n++ {
			addMessage(&s, "assistant", strings.Repeat("\"\n<>&", 2400)+fmt.Sprint(n))
		}
		addMessage(&s, "user", "最新更正：部署失败，尚未完成")
		finishSession(&s)
		c.Sessions = append(c.Sessions, s)
	}
	usage, _ := json.Marshal(c.Usage)
	prompt, err := summaryPrompt(c)
	if err != nil {
		t.Fatal(err)
	}
	if utf8.RuneCountInString(prompt) > maxSummaryInputChars {
		t.Fatal("escaped prompt exceeded CLI input cap")
	}
	if !slices.Contains(c.Warnings, "journal_prompt_limit_reached") || c.Coverage[0].State != "degraded" {
		t.Fatal("trimming not reported")
	}
	for _, s := range c.Sessions {
		if s.Messages[len(s.Messages)-1].Content != "最新更正：部署失败，尚未完成" {
			t.Fatal("latest correction lost")
		}
	}
	after, _ := json.Marshal(c.Usage)
	if !bytes.Equal(usage, after) {
		t.Fatal("token usage changed while trimming")
	}
	small := &Corpus{Schema: 1, Date: c.Date, Timezone: c.Timezone, Coverage: []Coverage{}, Usage: map[string]any{}, Sessions: []Session{{ID: "small", Messages: []Message{{"user", "正常语料"}}}}, Warnings: []string{}}
	if _, err = summaryPrompt(small); err != nil || small.Sessions[0].Messages[0].Content != "正常语料" || len(small.Warnings) != 0 {
		t.Fatal("short input was altered")
	}
}

func TestJournalLiveCodex(t *testing.T) {
	if os.Getenv("TODO_CALENDAR_LIVE_AI") != "1" {
		t.Skip("explicit local Codex verification only")
	}
	c := &Corpus{Schema: 1, Date: "2026-10-29", Timezone: "Asia/Shanghai", Coverage: []Coverage{}, Usage: map[string]any{"state": "unsupported", "reason": "test_fixture", "input_tokens": nil}, Warnings: []string{}, Sessions: []Session{{Source: "codex", ID: "synthetic-verification", Title: "隔离验收", Eligibility: Eligibility{State: "included", Length: "normal"}, Messages: []Message{{"user", "这是隔离验收语料：请检查日历接口。"}, {"assistant", "仅完成了接口阅读，尚未执行测试或部署。"}}}}}
	duration := 90 * time.Second
	if os.Getenv("TODO_CALENDAR_LIVE_DAY") != "" {
		duration = 480 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	if os.Getenv("TODO_CALENDAR_LIVE_DAY") != "" {
		home, _ := os.UserHomeDir()
		var collectErr error
		c, collectErr = collectJournal(ctx, home, os.Getenv("TODO_CALENDAR_LIVE_DAY"), "Asia/Shanghai")
		if collectErr != nil {
			cancel()
			t.Fatal(collectErr)
		}
		size := 0
		for _, s := range c.Sessions {
			size += s.Eligibility.Chars
		}
		prompt, prepareErr := summaryPrompt(c)
		if prepareErr != nil {
			cancel()
			t.Fatal(prepareErr)
		}
		t.Logf("real selected-day input: %d sessions, %d retained characters before prompt budget, %d serialized prompt characters", len(c.Sessions), size, utf8.RuneCountInString(prompt))
	}
	defer cancel()
	s, err := runSummary(ctx, c)
	if err != nil {
		t.Fatal(err)
	}
	if s == nil || s.Body == "" || s.Date != c.Date {
		t.Fatal("missing summary")
	}
	t.Logf("real local Codex returned validated summary: %d bytes, %d work items", len(s.Body), len(s.Work))
}

func TestJournalRedactsWholePrivateKeysAndKeepsLatestCorrection(t *testing.T) {
	for _, kind := range []string{"PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY", "OPENSSH PRIVATE KEY", "ENCRYPTED PRIVATE KEY"} {
		for _, closed := range []bool{true, false} {
			text := "前言\n-----BEGIN " + kind + "-----\nsynthetic-secret-material\n"
			if closed {
				text += "-----END " + kind + "-----\n安全结尾"
			}
			cleaned := cleanText(text)
			if strings.Contains(cleaned, "synthetic-secret") || strings.Contains(cleaned, "PRIVATE KEY") {
				t.Fatalf("private key retained: %q", cleaned)
			}
		}
	}
	s := Session{}
	for i := 0; i < 8; i++ {
		addMessage(&s, "assistant", strings.Repeat(fmt.Sprint(i), 16000))
	}
	addMessage(&s, "user", "更正：部署失败，尚未完成")
	finishSession(&s)
	if !s.Truncated || s.Messages[len(s.Messages)-1].Content != "更正：部署失败，尚未完成" || s.Eligibility.Chars > 64000 {
		t.Fatalf("latest correction lost: %+v", s.Eligibility)
	}
}
