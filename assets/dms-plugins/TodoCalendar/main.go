package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

const maxStore = 64 << 20
const maxRecords = 20000
const schema = "dms.todo.calendar.v1"

type Note struct {
	ID       string   `json:"id"`
	Title    string   `json:"title"`
	Body     string   `json:"body_markdown"`
	Date     *string  `json:"diary_date"`
	Tags     []string `json:"tags"`
	Status   string   `json:"status"`
	Pinned   bool     `json:"pinned"`
	Created  int64    `json:"created_at_ms"`
	Updated  int64    `json:"updated_at_ms"`
	Deleted  *int64   `json:"deleted_at_ms"`
	Revision int64    `json:"revision"`
}

type Summary struct {
	ID       string  `json:"id"`
	Title    string  `json:"title"`
	Date     *string `json:"diary_date"`
	Status   string  `json:"status"`
	Pinned   bool    `json:"pinned"`
	Updated  int64   `json:"updated_at_ms"`
	Revision int64   `json:"revision"`
	Preview  string  `json:"preview"`
	Total    int     `json:"total"`
	Done     int     `json:"done"`
}

type Item struct {
	Index   int    `json:"index"`
	Line    int    `json:"line"`
	Checked bool   `json:"checked"`
	Text    string `json:"text"`
}

type Request struct {
	Action   string `json:"action"`
	Date     string `json:"local_date"`
	Timezone string `json:"timezone"`
	Month    string `json:"month"`
	ID       string `json:"id"`
	Revision int64  `json:"expected_revision"`
	Note     *Note  `json:"note"`
	Path     string `json:"path"`
}

type Data struct {
	Notes     []Summary `json:"notes"`
	Journal   *Journal  `json:"journal,omitempty"`
	Note      *Note     `json:"note,omitempty"`
	Imported  int       `json:"imported"`
	Skipped   int       `json:"skipped"`
	ReadAt    int64     `json:"read_at_ms"`
	Committed bool      `json:"committed"`
}

type Response struct {
	OK      bool   `json:"ok"`
	State   string `json:"state"`
	Reason  string `json:"reason"`
	Message string `json:"message"`
	Data    *Data  `json:"data,omitempty"`
}

type disk struct {
	Schema string `json:"schema"`
	Notes  []Note `json:"notes"`
}

type problem struct{ reason, message string }

func (p *problem) Error() string        { return p.reason }
func fail(reason, message string) error { return &problem{reason, message} }

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)
var checkPattern = regexp.MustCompile(`^[ \t]*[-*+] \[([ xX])\][ \t]*(.*)$`)

func validDate(value string) bool {
	t, err := time.Parse("2006-01-02", value)
	return err == nil && t.Format("2006-01-02") == value && t.Year() > 0
}

func validate(n *Note, imported bool) error {
	if !utf8.ValidString(n.Title) || !utf8.ValidString(n.Body) || strings.ContainsRune(n.Title+n.Body, 0) || utf8.RuneCountInString(n.Title) > 512 || len(n.Body) > 4<<20 {
		return fail("invalid_content", "标题最多 512 个字，正文最多 4 MiB，且不能包含无效字符。")
	}
	if n.Date != nil && !validDate(*n.Date) {
		return fail("invalid_date", "日期格式应为有效的 YYYY-MM-DD。")
	}
	if n.Status != "draft" && n.Status != "active" && n.Status != "completed" && n.Status != "archived" {
		return fail("invalid_status", "记录状态无效。")
	}
	if len(n.Tags) > 64 {
		return fail("invalid_tags", "最多保留 64 个标签。")
	}
	for _, tag := range n.Tags {
		if tag == "" || !utf8.ValidString(tag) || strings.ContainsRune(tag, 0) || utf8.RuneCountInString(tag) > 64 {
			return fail("invalid_tags", "每个标签应为 1 到 64 个字。")
		}
	}
	if n.Tags == nil {
		n.Tags = []string{}
	}
	if (n.ID != "" && !uuidPattern.MatchString(n.ID)) || n.Revision < 0 || n.Revision >= 1<<53 || (imported && (n.ID == "" || n.Revision == 0)) {
		return fail("invalid_record", "记录标识或版本无效。")
	}
	if n.Created < 0 || n.Updated < n.Created || n.Updated >= 1<<53 || (n.Deleted != nil && (*n.Deleted < 0 || *n.Deleted >= 1<<53)) {
		return fail("invalid_record", "记录的时间字段无效。")
	}
	return nil
}

func checklist(body string) []Item {
	items := []Item{}
	fence := ""
	for row, line := range strings.Split(body, "\n") {
		trim := strings.TrimSpace(line)
		if strings.HasPrefix(trim, "```") || strings.HasPrefix(trim, "~~~") {
			marker := trim[:3]
			if fence == "" {
				fence = marker
			} else if fence == marker {
				fence = ""
			}
			continue
		}
		if fence != "" {
			continue
		}
		match := checkPattern.FindStringSubmatch(strings.TrimSuffix(line, "\r"))
		if match != nil {
			items = append(items, Item{len(items), row, match[1] != " ", match[2]})
		}
	}
	return items
}

func toggle(body string, index int, checked bool) (string, error) {
	items := checklist(body)
	if index < 0 || index >= len(items) {
		return "", fail("item_not_found", "待办已变化，请重新读取记录。")
	}
	lines := strings.Split(body, "\n")
	row := items[index].Line
	position := strings.Index(lines[row], "[")
	mark := " "
	if checked {
		mark = "x"
	}
	lines[row] = lines[row][:position+1] + mark + lines[row][position+2:]
	return strings.Join(lines, "\n"), nil
}

func decode(reader io.Reader, limit int64, value any) error {
	limited := &io.LimitedReader{R: reader, N: limit + 1}
	decoder := json.NewDecoder(limited)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return errors.New("expected one json value")
	}
	if limited.N <= 0 {
		return errors.New("json exceeds limit")
	}
	return nil
}

func stateDir() (string, error) {
	base := os.Getenv("XDG_STATE_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		base = filepath.Join(home, ".local", "state")
	}
	if !filepath.IsAbs(base) {
		return "", errors.New("state directory must be absolute")
	}
	return filepath.Join(base, "dms-todo-calendar"), nil
}

func privateFile(root *os.Root, name string) error {
	info, err := root.Lstat(name)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return fail("unsafe_storage", "存储文件类型或访问权限不正确，请检查插件数据目录。")
	}
	return nil
}

func handle(path string, req Request) Response {
	data, err := execute(path, req)
	if err == nil {
		return Response{true, "healthy", "ready", "本地记录已读取", data}
	}
	var p *problem
	if errors.As(err, &p) {
		return Response{false, "degraded", p.reason, p.message, data}
	}
	if errors.Is(err, os.ErrPermission) {
		return Response{false, "unreachable", "permission_denied", "无权访问本地数据，请检查文件权限。草稿仍保留。", nil}
	}
	return Response{false, "unreachable", "storage_unavailable", "无法读取或保存本地数据，请检查数据目录后重试。草稿仍保留。", nil}
}

func execute(path string, req Request) (*Data, error) {
	month, err := time.Parse("2006-01", req.Month)
	if err != nil || month.Year() < 1 || month.Year() > 9998 {
		return nil, fail("invalid_month", "月份无效。")
	}
	var incoming []Note
	if req.Action == "import" {
		incoming, err = readImport(req.Path)
		if err != nil {
			return nil, err
		}
	}
	if err = os.MkdirAll(path, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return nil, fail("unsafe_storage", "插件数据目录必须是仅当前用户可访问的普通目录。")
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	for _, name := range []string{"notes.json", "notes.lock"} {
		if err = privateFile(root, name); err != nil {
			return nil, err
		}
	}
	lock, err := root.OpenFile("notes.lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	deadline := time.Now().Add(2 * time.Second)
	for {
		err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
			return nil, err
		}
		if time.Now().After(deadline) {
			return nil, fail("storage_busy", "另一个保存操作正在进行，请稍后重试。")
		}
		time.Sleep(20 * time.Millisecond)
	}
	stored := disk{Schema: schema, Notes: []Note{}}
	file, err := root.Open("notes.json")
	if err == nil {
		readErr := decode(file, maxStore, &stored)
		closeErr := file.Close()
		if readErr != nil || stored.Schema != schema || len(stored.Notes) > maxRecords {
			return nil, fail("storage_invalid", "本地数据格式无法识别，已停止写入以保留原文件。")
		}
		if closeErr != nil {
			return nil, closeErr
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	byID := make(map[string]int, len(stored.Notes))
	for index := range stored.Notes {
		n := &stored.Notes[index]
		if err = validate(n, true); err != nil {
			return nil, fail("storage_invalid", "本地记录损坏，已停止写入以保留原文件。")
		}
		if _, exists := byID[n.ID]; exists {
			return nil, fail("storage_invalid", "本地数据含重复标识，已停止写入。")
		}
		byID[n.ID] = index
	}
	data := &Data{Notes: []Summary{}, ReadAt: time.Now().UnixMilli()}
	changed := false
	switch req.Action {
	case "snapshot":
	case "get", "delete":
		index, ok := byID[req.ID]
		if !ok || stored.Notes[index].Deleted != nil {
			return nil, fail("note_not_found", "记录不存在或已删除，请刷新列表。")
		}
		if req.Action == "get" {
			n := stored.Notes[index]
			data.Note = &n
			break
		}
		if req.Revision != stored.Notes[index].Revision {
			return nil, fail("revision_conflict", "记录已被其他操作修改，请保留草稿并重新读取。")
		}
		if stored.Notes[index].Revision >= (1<<53)-1 {
			return nil, fail("revision_exhausted", "记录版本已达到上限，未修改原文件。")
		}
		stamp := max(time.Now().UnixMilli(), stored.Notes[index].Updated)
		stored.Notes[index].Deleted = &stamp
		stored.Notes[index].Updated = stamp
		stored.Notes[index].Revision++
		changed = true
	case "save":
		if req.Note == nil {
			return nil, fail("invalid_request", "缺少要保存的记录。")
		}
		n := *req.Note
		if err = validate(&n, false); err != nil {
			return nil, err
		}
		stamp := time.Now().UnixMilli()
		if n.ID == "" {
			return nil, fail("invalid_record", "缺少稳定的记录编号，请重新创建草稿。")
		}
		if n.Revision == 0 {
			if n.Deleted != nil {
				return nil, fail("invalid_record", "新记录的版本无效。")
			}
			if index, exists := byID[n.ID]; exists {
				current := stored.Notes[index]
				retry := n
				retry.Created, retry.Updated, retry.Revision = current.Created, current.Updated, current.Revision
				if current.Deleted != nil || current.Revision != 1 || !reflect.DeepEqual(retry, current) {
					return nil, fail("revision_conflict", "该新建编号已经存在不同内容，请保留草稿并重新读取。")
				}
				data.Note = &current
				break
			}
			if len(stored.Notes) >= maxRecords {
				return nil, fail("storage_full", "已达到本地记录数量上限。")
			}
			n.Created, n.Updated, n.Revision = stamp, stamp, 1
			stored.Notes = append(stored.Notes, n)
		} else {
			index, ok := byID[n.ID]
			if !ok || stored.Notes[index].Deleted != nil {
				return nil, fail("note_not_found", "记录不存在或已删除，草稿仍保留。")
			}
			if n.Revision != stored.Notes[index].Revision {
				return nil, fail("revision_conflict", "记录已被其他操作修改，请保留草稿并重新读取。")
			}
			if n.Revision >= (1<<53)-1 {
				return nil, fail("revision_exhausted", "记录版本已达到上限，未修改原文件。")
			}
			stamp = max(stamp, stored.Notes[index].Updated)
			n.Created, n.Updated, n.Revision, n.Deleted = stored.Notes[index].Created, stamp, n.Revision+1, nil
			stored.Notes[index] = n
		}
		data.Note, changed = &n, true
	case "import":
		seen := make(map[string]bool, len(incoming))
		for _, n := range incoming {
			if seen[n.ID] {
				return nil, fail("import_invalid", "导入文件包含重复的记录标识，未写入任何记录。")
			}
			seen[n.ID] = true
			if index, exists := byID[n.ID]; exists {
				if !reflect.DeepEqual(stored.Notes[index], n) {
					return nil, fail("import_conflict", "已有同标识、不同内容的记录。为避免覆盖，未写入本次导入；请先核对两个来源。")
				}
				data.Skipped++
			} else {
				stored.Notes = append(stored.Notes, n)
				data.Imported++
			}
		}
		if len(stored.Notes) > maxRecords {
			return nil, fail("storage_full", "导入后将超过 20,000 条记录，未写入任何记录。")
		}
		changed = data.Imported > 0
	default:
		return nil, fail("invalid_action", "不支持此操作。")
	}
	if changed {
		for i := range stored.Notes {
			if err = validate(&stored.Notes[i], true); err != nil {
				return nil, err
			}
		}
		bytes, err := json.Marshal(stored)
		if err != nil {
			return nil, err
		}
		if len(bytes) > maxStore {
			return nil, fail("storage_full", "本地数据超过 64 MiB，未覆盖原文件。")
		}
		name := fmt.Sprintf(".notes-%d-%d.tmp", os.Getpid(), time.Now().UnixNano())
		tmp, err := root.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if err != nil {
			return nil, err
		}
		defer root.Remove(name)
		_, writeErr := tmp.Write(bytes)
		syncErr := tmp.Sync()
		closeErr := tmp.Close()
		if err = errors.Join(writeErr, syncErr, closeErr); err != nil {
			return nil, err
		}
		if err = root.Rename(name, "notes.json"); err != nil {
			return nil, err
		}
		data.Committed = true
		directory, err := root.Open(".")
		if err != nil {
			return data, fail("durability_unconfirmed", "文件已替换，但持久性尚未确认。请重新读取核对；草稿仍保留。")
		}
		syncErr = directory.Sync()
		closeErr = directory.Close()
		if err = errors.Join(syncErr, closeErr); err != nil {
			return data, fail("durability_unconfirmed", "文件已替换，但磁盘同步失败。请重新读取核对；草稿仍保留。")
		}
	}
	start := month.AddDate(0, 0, -(int(month.Weekday())+6)%7).Format("2006-01-02")
	endTime, _ := time.Parse("2006-01-02", start)
	end := endTime.AddDate(0, 0, 41).Format("2006-01-02")
	for _, n := range stored.Notes {
		if n.Deleted != nil || (n.Date != nil && (*n.Date < start || *n.Date > end)) {
			continue
		}
		items, done := checklist(n.Body), 0
		for _, item := range items {
			if item.Checked {
				done++
			}
		}
		preview := []rune(strings.Join(strings.Fields(n.Body), " "))
		if len(preview) > 160 {
			preview = append(preview[:160], '…')
		}
		data.Notes = append(data.Notes, Summary{n.ID, n.Title, n.Date, n.Status, n.Pinned, n.Updated, n.Revision, string(preview), len(items), done})
	}
	sort.Slice(data.Notes, func(i, j int) bool {
		a, b := data.Notes[i], data.Notes[j]
		if a.Pinned != b.Pinned {
			return a.Pinned
		}
		if a.Updated != b.Updated {
			return a.Updated > b.Updated
		}
		return a.ID < b.ID
	})
	return data, nil
}

func main() {
	var req Request
	response := Response{false, "degraded", "invalid_request", "请求格式无效。", nil}
	if err := decode(os.Stdin, 8<<20, &req); err == nil {
		if path, err := stateDir(); err == nil {
			if req.Action == "journal_cache" || req.Action == "journal_collect" || req.Action == "journal_summarize" {
				ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
				ctx, cancel := context.WithTimeout(ctx, 490*time.Second)
				data, requestErr := journalRequest(ctx, path, req)
				cancel()
				stop()
				response = journalResponse(data, requestErr)
			} else {
				response = handle(path, req)
			}
		} else {
			response = Response{false, "unreachable", "state_directory_unavailable", "无法确定本地存储位置。", nil}
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(response); err != nil {
		os.Exit(1)
	}
}
