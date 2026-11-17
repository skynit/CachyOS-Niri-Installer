package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	_ "modernc.org/sqlite"
)

func readImport(path string) ([]Note, error) {
	if !filepath.IsAbs(path) {
		return nil, fail("import_path_invalid", "请选择本地导出 JSON 或原应用的 notes.sqlite3 文件。")
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxStore {
		return nil, fail("import_invalid", "导入文件必须是小于 64 MiB 的普通文件。")
	}
	var header [16]byte
	_, err = io.ReadFull(file, header[:])
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return nil, err
	}
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	var notes []Note
	if string(header[:]) == "SQLite format 3\x00" {
		notes, err = readSQLite(path)
	} else {
		var value disk
		if err = decode(file, maxStore, &value); err != nil {
			return nil, fail("import_invalid", "无法解析导出 JSON；请使用原应用的 JSON 导出格式。")
		}
		if value.Schema != "localdesk.notes.export.v1" && value.Schema != schema {
			return nil, fail("import_schema_unsupported", "不支持此导出格式。")
		}
		notes = value.Notes
	}
	if err != nil {
		return nil, err
	}
	if len(notes) > maxRecords {
		return nil, fail("import_invalid", "导入文件超过 20,000 条记录。")
	}
	for i := range notes {
		if err = validate(&notes[i], true); err != nil {
			return nil, err
		}
	}
	return notes, nil
}

func readSQLite(path string) ([]Note, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	uri := url.URL{Scheme: "file", Path: path}
	q := url.Values{"mode": {"ro"}, "_pragma": {"query_only(1)", "busy_timeout(1500)"}}
	uri.RawQuery = q.Encode()
	db, err := sql.Open("sqlite", uri.String())
	if err != nil {
		return nil, err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	var version int
	if err = db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&version); err != nil {
		return nil, fail("import_database_unavailable", "无法只读打开原数据库，请检查访问权限与文件完整性。")
	}
	if version != 3 {
		return nil, fail("import_schema_unsupported", "只支持已核对的原应用数据库版本 3；请改用 JSON 导出文件。")
	}
	rows, err := db.QueryContext(ctx, `SELECT n.id,n.title,n.body_markdown,n.diary_date,n.status,n.pinned,n.created_at_ms,n.updated_at_ms,n.deleted_at_ms,n.revision,
	 COALESCE((SELECT json_group_array(display_tag) FROM (SELECT display_tag FROM note_tags WHERE note_id=n.id ORDER BY tag_key)), '[]')
	 FROM notes n ORDER BY n.id LIMIT 20001`)
	if err != nil {
		return nil, fail("import_database_invalid", "原数据库的记录结构无法识别，请改用 JSON 导出。")
	}
	defer rows.Close()
	notes, size := []Note{}, 0
	for rows.Next() {
		var n Note
		var tags string
		if err = rows.Scan(&n.ID, &n.Title, &n.Body, &n.Date, &n.Status, &n.Pinned, &n.Created, &n.Updated, &n.Deleted, &n.Revision, &tags); err != nil {
			return nil, err
		}
		if err = json.Unmarshal([]byte(tags), &n.Tags); err != nil {
			return nil, err
		}
		size += len(n.Body) + len(n.Title) + len(strings.Join(n.Tags, ""))
		if size > maxStore {
			return nil, fail("import_invalid", "原数据库内容超过 64 MiB，未写入任何记录。")
		}
		notes = append(notes, n)
	}
	if err = rows.Err(); err != nil {
		return nil, err
	}
	return notes, nil
}
