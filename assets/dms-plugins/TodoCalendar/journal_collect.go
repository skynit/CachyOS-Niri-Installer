package main

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
)

const maxSessionChars = 64000

func bounded(text string, limit int) string {
	r := []rune(text)
	if len(r) > limit {
		r = r[:limit]
	}
	return string(r)
}

var privateKeyStart = regexp.MustCompile(`(?i)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----`)
var privateKeyEnd = regexp.MustCompile(`(?i)-----END [A-Z0-9 ]*PRIVATE KEY-----`)

func cleanText(text string) string {
	text = strings.TrimSpace(text)
	for _, prefix := range []string{"<codex_internal_context", "<environment_context", "<recommended_plugins", "# AGENTS.md instructions", "<permissions instructions", "<skills_instructions", "<app-context>"} {
		if strings.HasPrefix(text, prefix) {
			return ""
		}
	}
	output := []string{}
	inKey := false
	for _, line := range strings.Split(text, "\n") {
		if privateKeyStart.MatchString(line) {
			inKey = true
			output = append(output, "[redacted private key]")
		}
		if inKey {
			if privateKeyEnd.MatchString(line) {
				inKey = false
			}
			continue
		}
		lower := strings.ToLower(line)
		for _, secret := range []string{"authorization:", "api_key=", "api-key:", "password=", "\"access_token\"", "\"refresh_token\""} {
			if strings.Contains(lower, secret) {
				line = "[redacted sensitive line]"
				break
			}
		}
		output = append(output, line)
	}
	return strings.Join(output, "\n")
}
func addMessage(s *Session, role, text string) {
	if role != "user" && role != "assistant" {
		return
	}
	text = cleanText(text)
	if text == "" {
		return
	}
	runes := []rune(text)
	if len(runes) > 16000 {
		text = string(runes[len(runes)-16000:])
		s.Truncated = true
	}
	if len(s.Messages) > 0 {
		last := s.Messages[len(s.Messages)-1]
		if last.Role == role && last.Content == text {
			return
		}
	}
	s.Messages = append(s.Messages, Message{role, text})
	chars := 0
	for _, message := range s.Messages {
		chars += len([]rune(message.Content))
	}
	for chars > maxSessionChars && len(s.Messages) > 0 {
		first := []rune(s.Messages[0].Content)
		remove := chars - maxSessionChars
		if remove >= len(first) {
			chars -= len(first)
			s.Messages = s.Messages[1:]
		} else {
			s.Messages[0].Content = string(first[remove:])
			chars -= remove
		}
		s.Truncated = true
	}
}
func finishSession(s *Session) {
	count := 0
	for _, m := range s.Messages {
		count += len([]rune(m.Content))
	}
	e := Eligibility{State: "ignored_short", Reason: "below_default_threshold", Messages: len(s.Messages), Chars: count, Length: "short"}
	if e.Messages >= 4 || count >= 1200 {
		e.State = "included"
		e.Reason = "meets_default_threshold"
		e.Length = "normal"
	}
	if e.Messages >= 24 || count >= 12000 {
		e.Length = "long"
	}
	s.Eligibility = e
	if s.Title == "" {
		for _, m := range s.Messages {
			if m.Role == "user" {
				s.Title = bounded(strings.Split(m.Content, "\n")[0], 120)
				break
			}
		}
	}
	if s.Title == "" {
		s.Title = "未命名会话"
	}
}
func sourcePath(home, source string) string {
	switch source {
	case "codex":
		return filepath.Join(home, ".codex", "sessions")
	case "claude":
		return filepath.Join(home, ".claude", "projects")
	default:
		return filepath.Join(home, ".local", "share", "opencode", "opencode.db")
	}
}
func ownedFile(path string, limit int64) (*os.File, error) {
	// Resolve parents too: an indexed symlink must not escape its fixed source root.
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil || canonical != filepath.Clean(path) {
		return nil, fail("session_file_unsafe", "会话路径含符号链接或不可读。")
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !info.Mode().IsRegular() || !ok || stat.Uid != uint32(os.Geteuid()) || (limit > 0 && info.Size() > limit) {
		f.Close()
		return nil, fail("session_file_unsafe", "会话来源不是当前用户的安全普通文件。")
	}
	return f, nil
}
func readOnlyDB(path string) (*sql.DB, error) {
	f, err := ownedFile(path, 0)
	if err != nil {
		return nil, err
	}
	f.Close()
	uri := url.URL{Scheme: "file", Path: path}
	uri.RawQuery = url.Values{"mode": {"ro"}, "_pragma": {"query_only(1)", "busy_timeout(1500)"}}.Encode()
	db, err := sql.Open("sqlite", uri.String())
	if err == nil {
		db.SetMaxOpenConns(1)
	}
	return db, err
}
func textValue(v map[string]any, key string) string { s, _ := v[key].(string); return s }
func textParts(content any) string {
	if s, ok := content.(string); ok {
		return s
	}
	parts, _ := content.([]any)
	out := []string{}
	for _, p := range parts {
		m, _ := p.(map[string]any)
		kind := textValue(m, "type")
		if kind == "text" || kind == "input_text" || kind == "output_text" {
			out = append(out, textValue(m, "text"))
		}
	}
	return strings.Join(out, "\n")
}
func parseSession(ctx context.Context, home, source, path string, stamp int64) (Session, error) {
	s := Session{Source: source, ID: strings.TrimSuffix(filepath.Base(path), filepath.Ext(path)), Updated: stamp, Messages: []Message{}}
	base := sourcePath(home, source)
	rel, err := filepath.Rel(base, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return s, fail("session_path_outside_root", "会话路径越出来源目录。")
	}
	f, err := ownedFile(path, 64<<20)
	if err != nil {
		return s, err
	}
	defer f.Close()
	scanner := bufio.NewScanner(io.LimitReader(f, (64<<20)+1))
	scanner.Buffer(make([]byte, 65536), 8<<20)
	for scanner.Scan() {
		if ctx.Err() != nil {
			return s, ctx.Err()
		}
		var v map[string]any
		if json.Unmarshal(scanner.Bytes(), &v) != nil {
			continue
		}
		if source == "codex" {
			payload, _ := v["payload"].(map[string]any)
			if textValue(v, "type") == "session_meta" {
				if id := textValue(payload, "id"); id != "" {
					s.ID = id
				} else if id = textValue(payload, "session_id"); id != "" {
					s.ID = id
				}
				if cwd := textValue(payload, "cwd"); cwd != "" {
					s.Workspace = &cwd
				}
				continue
			}
			if textValue(v, "type") == "response_item" && textValue(payload, "type") == "message" {
				addMessage(&s, textValue(payload, "role"), textParts(payload["content"]))
			}
		} else {
			message, _ := v["message"].(map[string]any)
			role := textValue(message, "role")
			if role != "user" && role != "assistant" {
				continue
			}
			if id := textValue(v, "sessionId"); id != "" {
				s.ID = id
			} else if id = textValue(v, "session_id"); id != "" {
				s.ID = id
			}
			if cwd := textValue(v, "cwd"); cwd != "" {
				s.Workspace = &cwd
			}
			addMessage(&s, role, textParts(message["content"]))
		}
	}
	if err = scanner.Err(); err != nil {
		return s, err
	}
	finishSession(&s)
	return s, nil
}
func epochMS(value int64) int64 {
	if value < 0 {
		return -1
	}
	if value >= 100000000000000000 {
		return value / 1000000
	}
	if value >= 100000000000 {
		return value
	}
	return value * 1000
}
func appSource(s string) string {
	if s == "claude-desktop" {
		return "claude"
	}
	return s
}
func tokenUsage(ctx context.Context, db *sql.DB, start, end int64) map[string]any {
	usage := map[string]any{"state": "degraded", "reason": "cc_switch_usage_query_failed", "window_start_ms": start, "window_end_ms": end, "last_synced_at_ms": nil, "input_tokens": nil, "output_tokens": nil, "cache_read_tokens": nil, "cache_creation_tokens": nil, "reported_total_tokens": nil, "total_method": "unavailable", "by_source": []any{}}
	rows, err := db.QueryContext(ctx, `SELECT app_type, COUNT(*),COALESCE(SUM(input_tokens),0),COALESCE(SUM(output_tokens),0),COALESCE(SUM(cache_read_tokens),0),COALESCE(SUM(cache_creation_tokens),0) FROM proxy_request_logs WHERE created_at>=? AND created_at<? GROUP BY app_type ORDER BY app_type`, start/1000, end/1000)
	if err != nil {
		return usage
	}
	sources := []any{}
	totals := [4]int64{}
	for rows.Next() {
		var source string
		var n int64
		var tokens [4]int64
		if err = rows.Scan(&source, &n, &tokens[0], &tokens[1], &tokens[2], &tokens[3]); err != nil {
			break
		}
		for i, v := range tokens {
			if v < 0 || v > (1<<53)-1-totals[i] {
				err = errors.New("invalid tokens")
				break
			}
			totals[i] += v
		}
		if err != nil {
			break
		}
		sources = append(sources, map[string]any{"source": appSource(source), "request_count": n, "input_tokens": tokens[0], "output_tokens": tokens[1], "cache_read_tokens": tokens[2], "cache_creation_tokens": tokens[3], "reported_total_tokens": tokens[0] + tokens[1]})
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return usage
	}
	usage["by_source"] = sources
	usage["state"] = "healthy"
	usage["reason"] = "cc_switch_no_usage_observed"
	if len(sources) > 0 {
		usage["reason"] = "cc_switch_usage_ready"
		for i, key := range []string{"input_tokens", "output_tokens", "cache_read_tokens", "cache_creation_tokens"} {
			usage[key] = totals[i]
		}
		usage["reported_total_tokens"] = totals[0] + totals[1]
		usage["total_method"] = "input_plus_output"
	}
	var last sql.NullInt64
	syncErr := db.QueryRowContext(ctx, `SELECT MAX(last_synced_at) FROM session_log_sync`).Scan(&last)
	if syncErr == nil && last.Valid {
		usage["last_synced_at_ms"] = epochMS(last.Int64)
	}
	var semantics int
	semanticsErr := db.QueryRowContext(ctx, `SELECT COUNT(DISTINCT input_token_semantics) FROM proxy_request_logs WHERE created_at>=? AND created_at<?`, start/1000, end/1000).Scan(&semantics)
	now := time.Now().UnixMilli()
	if syncErr != nil {
		usage["state"] = "degraded"
		usage["reason"] = "cc_switch_sync_query_failed"
	} else if start <= now && now < end && (!last.Valid || now-epochMS(last.Int64) > 300000) {
		usage["state"] = "degraded"
		usage["reason"] = "cc_switch_session_sync_stale"
	} else if semanticsErr != nil {
		usage["state"] = "degraded"
		usage["reason"] = "cc_switch_usage_semantics_unknown"
	} else if semantics > 1 {
		usage["state"] = "degraded"
		usage["reason"] = "cc_switch_input_token_semantics_mixed"
	}
	return usage
}
func collectOpenCode(ctx context.Context, home string, start, end int64) ([]Session, error) {
	db, err := readOnlyDB(sourcePath(home, "opencode"))
	if err != nil {
		return nil, err
	}
	defer db.Close()
	rows, err := db.QueryContext(ctx, `SELECT id,title,directory,time_updated FROM session WHERE time_updated>=? AND time_updated<? ORDER BY time_updated DESC,id LIMIT 64`, start, end)
	if err != nil {
		return nil, err
	}
	sessions := []Session{}
	for rows.Next() {
		s := Session{Source: "opencode", Messages: []Message{}}
		var dir string
		if err = rows.Scan(&s.ID, &s.Title, &dir, &s.Updated); err != nil {
			break
		}
		s.Workspace = &dir
		sessions = append(sessions, s)
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return nil, err
	}
	for i := range sessions {
		rows, err = db.QueryContext(ctx, `SELECT m.data,p.data FROM message m JOIN part p ON p.message_id=m.id WHERE m.session_id=? ORDER BY m.time_created,p.time_created,p.id`, sessions[i].ID)
		if err != nil {
			return nil, err
		}
		size := 0
		for rows.Next() {
			var a, b string
			if err = rows.Scan(&a, &b); err != nil {
				break
			}
			size += len(a) + len(b)
			if size > 64<<20 {
				err = errors.New("opencode text limit")
				break
			}
			var m, p map[string]any
			if json.Unmarshal([]byte(a), &m) != nil || json.Unmarshal([]byte(b), &p) != nil {
				continue
			}
			if textValue(p, "type") == "text" {
				addMessage(&sessions[i], textValue(m, "role"), textValue(p, "text"))
			}
		}
		if err == nil {
			err = rows.Err()
		}
		rows.Close()
		if err != nil {
			return nil, err
		}
		finishSession(&sessions[i])
	}
	return sessions, nil
}
func collectJournal(ctx context.Context, home, date, zone string) (*Corpus, error) {
	_, start, end, err := journalWindow(date, zone)
	if err != nil {
		return nil, err
	}
	db, err := readOnlyDB(filepath.Join(home, ".cc-switch", "cc-switch.db"))
	if err != nil {
		return nil, fail("cc_switch_database_unavailable", "无法读取 cc-switch 本地数据库。请确认 cc-switch 已安装并已同步会话日志。")
	}
	defer db.Close()
	c := &Corpus{Schema: 1, Date: date, Timezone: zone, Coverage: []Coverage{}, Usage: tokenUsage(ctx, db, start.UnixMilli(), end.UnixMilli()), Sessions: []Session{}, Warnings: []string{}}
	configured := map[string]bool{}
	rows, err := db.QueryContext(ctx, `SELECT DISTINCT app_type FROM providers`)
	if err == nil {
		for rows.Next() {
			var name string
			if rows.Scan(&name) == nil {
				configured[appSource(name)] = true
			}
		}
		if rows.Err() != nil {
			c.Warnings = append(c.Warnings, "cc_switch_providers_partial")
		}
		rows.Close()
	} else {
		c.Warnings = append(c.Warnings, "cc_switch_providers_unavailable")
	}
	type indexed struct {
		source, path string
		stamp        int64
	}
	paths := []indexed{}
	tracked := map[string]bool{}
	rows, err = db.QueryContext(ctx, `SELECT file_path,last_modified FROM session_log_sync`)
	if err != nil {
		return nil, fail("cc_switch_session_index_unavailable", "cc-switch 会话索引不可读，请先同步会话日志。")
	}
	for rows.Next() {
		var path string
		var stamp int64
		if err = rows.Scan(&path, &stamp); err != nil {
			break
		}
		stamp = epochMS(stamp)
		if stamp < start.UnixMilli() || stamp >= end.UnixMilli() {
			continue
		}
		for _, source := range []string{"codex", "claude", "opencode"} {
			base := sourcePath(home, source)
			match := strings.HasPrefix(path, base+string(filepath.Separator))
			if source == "opencode" {
				match = path == base || strings.HasPrefix(path, base+":")
			}
			if match {
				tracked[source] = true
				paths = append(paths, indexed{source, path, stamp})
				break
			}
		}
		if len(paths) > 100000 {
			err = errors.New("index too large")
			break
		}
	}
	if err == nil {
		err = rows.Err()
	}
	rows.Close()
	if err != nil {
		return nil, fail("cc_switch_session_index_invalid", "cc-switch 会话索引异常或过大。")
	}
	sort.Slice(paths, func(i, j int) bool { return paths[i].stamp > paths[j].stamp })
	for _, source := range []string{"codex", "claude", "opencode"} {
		cov := Coverage{Source: source, State: "unsupported", Reason: "cc_switch_session_source_not_configured"}
		if !configured[source] && !tracked[source] {
			c.Coverage = append(c.Coverage, cov)
			continue
		}
		scanned, included, ignored := 0, 0, 0
		cov.Scanned = &scanned
		cov.Included = &included
		cov.Ignored = &ignored
		cov.State = "degraded"
		cov.Reason = "cc_switch_session_source_not_tracked"
		if !tracked[source] {
			c.Coverage = append(c.Coverage, cov)
			continue
		}
		cov.State = "healthy"
		cov.Reason = "session_source_ready"
		sessions := []Session{}
		partial := false
		if source == "opencode" {
			sessions, err = collectOpenCode(ctx, home, start.UnixMilli(), end.UnixMilli())
			partial = err != nil
		} else {
			seen := map[string]bool{}
			attempted := 0
			for _, path := range paths {
				if path.source != source || seen[path.path] {
					continue
				}
				seen[path.path] = true
				attempted++
				if attempted > 64 {
					partial = true
					break
				}
				s, readErr := parseSession(ctx, home, source, path.path, path.stamp)
				if readErr != nil {
					partial = true
					continue
				}
				sessions = append(sessions, s)
			}
		}
		scanned = len(sessions)
		for _, s := range sessions {
			if s.Eligibility.State == "included" {
				included++
			} else {
				ignored++
			}
		}
		if partial {
			cov.State = "degraded"
			cov.Reason = "session_source_partial"
			c.Warnings = append(c.Warnings, source+"_session_source_partial")
		}
		c.Coverage = append(c.Coverage, cov)
		c.Sessions = append(c.Sessions, sessions...)
	}
	sort.Slice(c.Sessions, func(i, j int) bool {
		if c.Sessions[i].Updated == c.Sessions[j].Updated {
			return c.Sessions[i].ID < c.Sessions[j].ID
		}
		return c.Sessions[i].Updated > c.Sessions[j].Updated
	})
	limitCorpus(c)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	return c, nil
}

// Limits apply before reporting included counts so the UI describes the
// actual model input, rather than sessions discarded by the total limit.
func limitCorpus(c *Corpus) {
	limited := map[string]bool{}
	seen := map[string]bool{}
	retained := []Session{}
	for _, session := range c.Sessions {
		if seen[session.ID] || len(retained) >= 64 {
			limited[session.Source] = true
			c.Warnings = append(c.Warnings, "session_candidate_limit_reached")
			continue
		}
		seen[session.ID] = true
		retained = append(retained, session)
	}
	c.Sessions = retained
	remaining := 1000000
	for i := range c.Sessions {
		session := &c.Sessions[i]
		if session.Truncated {
			limited[session.Source] = true
			c.Warnings = append(c.Warnings, session.Source+"_session_text_limit_reached")
		}
		messages := []Message{}
		for _, message := range session.Messages {
			chars := len([]rune(message.Content))
			if chars > remaining {
				message.Content = bounded(message.Content, remaining)
				limited[session.Source] = true
				c.Warnings = append(c.Warnings, "session_corpus_text_limit_reached")
			}
			remaining -= len([]rune(message.Content))
			if message.Content != "" {
				messages = append(messages, message)
			}
		}
		session.Messages = messages
		finishSession(session)
	}
	for i := range c.Coverage {
		coverage := &c.Coverage[i]
		if coverage.Included == nil {
			continue
		}
		included := 0
		for _, session := range c.Sessions {
			if session.Source == coverage.Source && session.Eligibility.State == "included" {
				included++
			}
		}
		coverage.Included = &included
		if limited[coverage.Source] {
			coverage.State = "degraded"
			coverage.Reason = "session_corpus_limited"
		}
	}
	warnings := []string{}
	seenWarnings := map[string]bool{}
	for _, warning := range c.Warnings {
		if !seenWarnings[warning] {
			seenWarnings[warning] = true
			warnings = append(warnings, warning)
		}
	}
	c.Warnings = warnings
}
