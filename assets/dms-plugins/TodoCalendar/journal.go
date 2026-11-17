package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

type Coverage struct {
	Source   string `json:"source"`
	State    string `json:"state"`
	Reason   string `json:"reason"`
	Scanned  *int   `json:"scanned_sessions"`
	Included *int   `json:"included_sessions"`
	Ignored  *int   `json:"ignored_short_sessions"`
}
type Eligibility struct {
	State    string `json:"state"`
	Reason   string `json:"reason"`
	Messages int    `json:"substantive_messages"`
	Chars    int    `json:"content_chars"`
	Length   string `json:"length_class"`
}
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}
type Session struct {
	Truncated   bool        `json:"truncated,omitempty"`
	Source      string      `json:"source"`
	ID          string      `json:"session_id"`
	Title       string      `json:"title"`
	Workspace   *string     `json:"workspace"`
	Updated     int64       `json:"updated_at_ms"`
	Eligibility Eligibility `json:"eligibility"`
	Messages    []Message   `json:"messages,omitempty"`
}
type Corpus struct {
	Schema   int            `json:"schema_version"`
	Date     string         `json:"local_date"`
	Timezone string         `json:"timezone"`
	Coverage []Coverage     `json:"source_coverage"`
	Usage    map[string]any `json:"token_usage"`
	Sessions []Session      `json:"sessions"`
	Warnings []string       `json:"warnings"`
}
type WorkItem struct {
	Workstream string   `json:"workstream"`
	State      string   `json:"state"`
	Summary    string   `json:"summary"`
	Evidence   []string `json:"evidence"`
	Sessions   []string `json:"source_session_ids"`
}
type KnowledgeItem struct {
	Topic    string   `json:"topic"`
	Summary  string   `json:"summary"`
	Sessions []string `json:"source_session_ids"`
}
type Candidate struct {
	Session     string `json:"source_session_id"`
	Recommended bool   `json:"recommended"`
	Reason      string `json:"reason"`
	Skill       string `json:"recommended_skill"`
}
type JournalSummary struct {
	Schema     int             `json:"schema_version"`
	Date       string          `json:"local_date"`
	Timezone   string          `json:"timezone"`
	Title      string          `json:"title"`
	Body       string          `json:"markdown_body"`
	Work       []WorkItem      `json:"work_items"`
	Knowledge  []KnowledgeItem `json:"knowledge_items"`
	Candidates []Candidate     `json:"knowledge_candidates"`
	Remaining  []string        `json:"remaining_items"`
	Coverage   []Coverage      `json:"source_coverage"`
	Usage      map[string]any  `json:"token_usage"`
	Warnings   []string        `json:"warnings"`
}
type Journal struct {
	SummaryCollection *Corpus         `json:"summary_collection"`
	SummaryUpdated    int64           `json:"summary_updated_at_ms"`
	Collection        *Corpus         `json:"collection"`
	Summary           *JournalSummary `json:"summary"`
	Updated           int64           `json:"updated_at_ms"`
}

func journalWindow(date, zone string) (*time.Location, time.Time, time.Time, error) {
	loc, err := time.LoadLocation(zone)
	if err != nil || zone == "" || zone == "Local" || !validDate(date) {
		return nil, time.Time{}, time.Time{}, fail("journal_date_invalid", "请选择有效日期和 IANA 时区，例如 Asia/Shanghai。")
	}
	start, err := time.ParseInLocation("2006-01-02", date, loc)
	if err != nil || start.Year() < 1970 || start.Year() > 9998 {
		return nil, time.Time{}, time.Time{}, fail("journal_date_invalid", "总结日期必须在 1970–9998 年内。")
	}
	return loc, start, start.AddDate(0, 0, 1), nil
}

func journalName(date, zone string) string {
	return fmt.Sprintf("%s-%x.json", date, sha256.Sum256([]byte(zone)))
}
func journalRoot(path string) (*os.Root, error) {
	if err := os.MkdirAll(path, 0700); err != nil {
		return nil, err
	}
	baseInfo, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !baseInfo.IsDir() || baseInfo.Mode()&os.ModeSymlink != 0 || baseInfo.Mode().Perm()&0077 != 0 {
		return nil, fail("unsafe_storage", "插件数据目录必须仅当前用户可访问。")
	}
	base, err := os.OpenRoot(path)
	if err != nil {
		return nil, err
	}
	defer base.Close()
	if err = base.Mkdir("journal", 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, err
	}
	info, err := base.Lstat("journal")
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return nil, fail("unsafe_storage", "AI 缓存目录必须仅当前用户可访问。")
	}
	return base.OpenRoot("journal")
}
func readJournal(path, date, zone string) (*Journal, error) {
	root, err := journalRoot(path)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	name := journalName(date, zone)
	if err = privateFile(root, name); err != nil {
		return nil, err
	}
	f, err := root.Open(name)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var entry Journal
	if err = decode(f, 8<<20, &entry); err != nil || entry.Collection == nil || entry.Collection.Date != date || entry.Collection.Timezone != zone {
		return nil, fail("journal_cache_invalid", "AI 缓存格式无效，请重新采集。")
	}
	if entry.Summary != nil {
		if entry.SummaryCollection == nil || entry.SummaryCollection.Date != date || entry.SummaryCollection.Timezone != zone {
			return nil, fail("journal_cache_invalid", "总结对应的来源快照无效，请重新生成。")
		}
		if err = validateSummary(entry.Summary, entry.SummaryCollection); err != nil {
			return nil, err
		}
	}
	return &entry, nil
}
func journalOverview(c *Corpus) *Corpus {
	if c == nil {
		return nil
	}
	overview := *c
	overview.Sessions = append([]Session{}, c.Sessions...)
	for i := range overview.Sessions {
		overview.Sessions[i].Messages = nil
	}
	return &overview
}
func writeJournal(path, date, zone string, entry *Journal) error {
	root, err := journalRoot(path)
	if err != nil {
		return err
	}
	defer root.Close()
	name := journalName(date, zone)
	if err = privateFile(root, name); err != nil {
		return err
	}
	saved := *entry
	saved.Collection = journalOverview(entry.Collection)
	saved.SummaryCollection = journalOverview(entry.SummaryCollection)
	payload, err := json.Marshal(saved)
	if err != nil {
		return err
	}
	if len(payload) > 8<<20 {
		return fail("journal_cache_too_large", "总结超出缓存上限。")
	}
	tmp := fmt.Sprintf(".%d-%d.tmp", os.Getpid(), time.Now().UnixNano())
	file, err := root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	defer root.Remove(tmp)
	_, err = file.Write(payload)
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err = root.Rename(tmp, name); err != nil {
		return err
	}
	directory, err := root.Open(".")
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
func sameJSON(a, b any) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	var u, v any
	_ = json.Unmarshal(x, &u)
	_ = json.Unmarshal(y, &v)
	return reflect.DeepEqual(u, v)
}
func validateSummary(s *JournalSummary, c *Corpus) error {
	invalid := func() error {
		return fail("journal_summary_invalid", "AI 返回了无效总结或改变了来源事实，结果未追加。请重试。")
	}
	if s.Schema != 1 || s.Date != c.Date || s.Timezone != c.Timezone || strings.TrimSpace(s.Title) == "" || strings.TrimSpace(s.Body) == "" || utf8.RuneCountInString(s.Title) > 512 || len(s.Body) > 2<<20 || !sameJSON(s.Coverage, c.Coverage) || !sameJSON(s.Usage, c.Usage) || s.Work == nil || s.Knowledge == nil || s.Candidates == nil || s.Remaining == nil || s.Warnings == nil {
		return invalid()
	}
	ids := map[string]Session{}
	for _, session := range c.Sessions {
		ids[session.ID] = session
	}
	references := func(refs []string) bool {
		if len(refs) == 0 {
			return false
		}
		seen := map[string]bool{}
		for _, id := range refs {
			session, ok := ids[id]
			if !ok || seen[id] || session.Eligibility.State != "included" {
				return false
			}
			seen[id] = true
		}
		return true
	}
	for _, w := range s.Work {
		if w.Workstream == "" || w.Summary == "" || len(w.Evidence) == 0 || !references(w.Sessions) || !(w.State == "completed" || w.State == "in_progress" || w.State == "blocked" || w.State == "decision") {
			return invalid()
		}
		for _, e := range w.Evidence {
			if strings.TrimSpace(e) == "" {
				return invalid()
			}
		}
	}
	for _, k := range s.Knowledge {
		if k.Topic == "" || k.Summary == "" || !references(k.Sessions) {
			return invalid()
		}
	}
	for _, k := range s.Candidates {
		session, ok := ids[k.Session]
		if !ok || k.Reason == "" || k.Skill != "capture-conversations-to-vault" || (k.Recommended && (session.Eligibility.Length != "long" || session.Eligibility.State != "included")) {
			return invalid()
		}
	}
	return nil
}
func localTimezone() string {
	if link, err := filepath.EvalSymlinks("/etc/localtime"); err == nil {
		if _, zone, ok := strings.Cut(link, "/zoneinfo/"); ok {
			return zone
		}
	}
	if raw, err := os.ReadFile("/etc/timezone"); err == nil {
		return strings.TrimSpace(string(raw))
	}
	if name := time.Now().Location().String(); name != "Local" {
		return name
	}
	return ""
}

func journalRequest(ctx context.Context, path string, req Request) (*Data, error) {
	if req.Timezone == "" {
		req.Timezone = localTimezone()
	}
	if _, _, _, err := journalWindow(req.Date, req.Timezone); err != nil {
		return nil, err
	}
	data := &Data{}
	if req.Action == "journal_cache" {
		entry, err := readJournal(path, req.Date, req.Timezone)
		data.Journal = entry
		return data, err
	}
	root, lockErr := journalRoot(path)
	if lockErr != nil {
		return nil, lockErr
	}
	defer root.Close()
	lockName := journalName(req.Date, req.Timezone) + ".lock"
	if err := privateFile(root, lockName); err != nil {
		return nil, err
	}
	lock, lockErr := root.OpenFile(lockName, os.O_CREATE|os.O_RDWR, 0600)
	if lockErr != nil {
		return nil, lockErr
	}
	defer lock.Close()
	if lockErr = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); lockErr != nil {
		return nil, fail("journal_busy", "该日期已有 AI 任务运行，请等待完成或取消后重试。")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	collectCtx, stop := context.WithTimeout(ctx, 30*time.Second)
	c, err := collectJournal(collectCtx, home, req.Date, req.Timezone)
	stop()
	if err != nil {
		return nil, err
	}
	entry := &Journal{Collection: c, Updated: time.Now().UnixMilli()}
	previous, cacheErr := readJournal(path, req.Date, req.Timezone)
	if cacheErr == nil && previous != nil {
		entry.Summary = previous.Summary
		entry.SummaryCollection = previous.SummaryCollection
		entry.SummaryUpdated = previous.SummaryUpdated
	}
	data.Journal = entry
	if req.Action == "journal_summarize" {
		included := false
		for _, s := range c.Sessions {
			included = included || s.Eligibility.State == "included"
		}
		if !included {
			return data, fail("journal_no_sessions", "当天没有达到总结条件的会话；请先检查来源与短会话数量。")
		}
		result, summaryErr := runSummary(ctx, c)
		if summaryErr != nil {
			return data, summaryErr
		}
		entry.Summary = result
		entry.SummaryCollection = c
		entry.SummaryUpdated = time.Now().UnixMilli()
	}
	if ctx.Err() != nil {
		return data, ctx.Err()
	}
	if err = writeJournal(path, req.Date, req.Timezone, entry); err != nil {
		return data, fail("journal_cache_write_failed", "结果已返回，但本地缓存未确认保存。请保留结果并检查目录权限。")
	}
	return data, nil
}
