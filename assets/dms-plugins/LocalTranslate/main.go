package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
	_ "modernc.org/sqlite"
)

type request struct {
	Text      string `json:"text"`
	Direction string `json:"direction"`
}

type entry struct {
	Simplified  string   `json:"simplified"`
	Traditional string   `json:"traditional"`
	Pinyin      string   `json:"pinyin"`
	Meanings    []string `json:"meanings"`
	Translation string   `json:"translation"`
}

func han(text string) bool {
	for _, r := range text {
		if r >= 0x3400 && r <= 0x9fff || r >= 0xf900 && r <= 0xfaff || r >= 0x20000 && r <= 0x323af {
			return true
		}
	}
	return false
}

func normalize(text string) string {
	text = cases.Fold().String(norm.NFKC.String(text))
	text = strings.NewReplacer("’", "'", "–", "-", "—", "-").Replace(text)
	return strings.Trim(strings.Join(strings.Fields(text), " "), " \t\n.!?。！？,，;；\"“”")
}

func base(text, direction string) map[string]any {
	return map[string]any{"query": text, "direction": direction, "entries": []entry{}, "suggestions": []string{}}
}

func failure(value map[string]any, reason, message string) map[string]any {
	value["status"], value["reason"], value["message"] = "error", reason, message
	return value
}

func search(text, mode, database string) map[string]any {
	text = strings.TrimSpace(text)
	if mode == "" {
		mode = "auto"
	}
	if mode != "auto" && mode != "zh" && mode != "en" {
		return failure(map[string]any{}, "invalid_direction", "翻译方向无效。")
	}
	direction := mode
	if direction == "auto" {
		direction = "en"
		if han(text) {
			direction = "zh"
		}
	}
	value := base(text, direction)
	if utf8.RuneCountInString(text) > 200 {
		return failure(value, "input_too_long", "最多输入 200 个字符，请查询词条或短语。")
	}
	key := normalize(text)
	if key == "" {
		value["status"], value["reason"], value["message"] = "idle", "empty_input", "输入中文或英文词条，离线查询。"
		return value
	}
	if !han(key) && !strings.ContainsFunc(key, func(r rune) bool { return r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' }) {
		value["status"], value["reason"], value["message"] = "empty", "unsupported_input", "请输入中文或英文词条。"
		return value
	}
	path, err := filepath.Abs(database)
	if err != nil {
		return failure(value, "dictionary_unavailable", "无法读取内置字典，请重新安装插件的 data 目录。")
	}
	file := url.URL{Scheme: "file", Path: path, RawQuery: "mode=ro"}
	db, err := sql.Open("sqlite", file.String())
	if err != nil {
		return failure(value, "dictionary_unavailable", "无法读取内置字典，请重新安装插件的 data 目录。")
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	var count string
	if err = db.QueryRow("SELECT value FROM metadata WHERE key='entries'").Scan(&count); err != nil {
		return failure(value, "dictionary_unavailable", "无法读取内置字典，请重新安装插件的 data 目录。")
	}
	number, err := strconv.Atoi(count)
	if err != nil {
		return failure(value, "dictionary_unavailable", "无法读取内置字典，请重新安装插件的 data 目录。")
	}
	value["dictionaryCount"] = number
	rows, err := db.Query(`SELECT e.simplified, e.traditional, e.pinyin, e.meanings, MIN(t.rank) AS match_rank
		FROM terms t JOIN entries e ON e.id = t.entry_id
		WHERE t.language = ? AND t.term = ? GROUP BY e.id
		ORDER BY match_rank, length(e.simplified), e.simplified, e.id LIMIT 21`, direction, key)
	if err != nil {
		return failure(value, "dictionary_unavailable", "无法读取内置字典，请重新安装插件的 data 目录。")
	}
	results := []entry{}
	for rows.Next() {
		var item entry
		var meanings string
		var rank int
		if err = rows.Scan(&item.Simplified, &item.Traditional, &item.Pinyin, &meanings, &rank); err != nil || json.Unmarshal([]byte(meanings), &item.Meanings) != nil {
			rows.Close()
			return failure(value, "dictionary_unavailable", "无法读取内置字典，请重新安装插件的 data 目录。")
		}
		item.Translation = item.Simplified
		if direction == "zh" {
			item.Translation = strings.Join(item.Meanings, "; ")
		}
		results = append(results, item)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return failure(value, "dictionary_unavailable", "无法读取内置字典，请重新安装插件的 data 目录。")
	}
	value["truncated"] = len(results) > 20
	if len(results) > 20 {
		results = results[:20]
	}
	value["entries"] = results
	if len(results) > 0 {
		value["status"], value["reason"], value["message"] = "ready", "exact_match", "内置字典匹配"
		return value
	}
	suggest, err := db.Query("SELECT DISTINCT term FROM terms WHERE language = ? AND term >= ? AND term < ? ORDER BY term LIMIT 8", direction, key, key+string(rune(0x10ffff)))
	if err != nil {
		return failure(value, "dictionary_unavailable", "无法读取内置字典，请重新安装插件的 data 目录。")
	}
	words := []string{}
	for suggest.Next() {
		var word string
		if err = suggest.Scan(&word); err != nil {
			suggest.Close()
			return failure(value, "dictionary_unavailable", "无法读取内置字典，请重新安装插件的 data 目录。")
		}
		words = append(words, word)
	}
	err = suggest.Err()
	suggest.Close()
	if err != nil {
		return failure(value, "dictionary_unavailable", "无法读取内置字典，请重新安装插件的 data 目录。")
	}
	value["suggestions"] = words
	value["status"], value["reason"], value["message"] = "empty", "not_found", "内置字典未收录此词条或短语；可缩短输入或查询原形词。"
	return value
}

func query(input []byte, database string) map[string]any {
	value := map[string]any{}
	if len(input) <= 16384 {
		var raw map[string]json.RawMessage
		if json.Unmarshal(input, &raw) != nil {
			value = failure(value, "invalid_request", "查询请求格式无效。")
		} else if raw != nil && raw["text"] != nil {
			var text string
			if json.Unmarshal(raw["text"], &text) == nil {
				mode := "auto"
				if raw["direction"] != nil && (string(raw["direction"]) == "null" || json.Unmarshal(raw["direction"], &mode) != nil) {
					mode = "invalid"
				}
				value = search(text, mode, database)
			} else {
				value = failure(value, "invalid_request", "请输入中文或英文词条。")
			}
		} else {
			value = failure(value, "invalid_request", "请输入中文或英文词条。")
		}
	} else {
		value = failure(value, "invalid_request", "查询请求格式无效。")
	}
	return value
}

func main() {
	input, err := io.ReadAll(io.LimitReader(os.Stdin, 16385))
	if err != nil {
		input = make([]byte, 16385)
	}
	binary, _ := os.Executable()
	value := query(input, filepath.Join(filepath.Dir(binary), "data", "dictionary.sqlite3"))
	data, err := json.Marshal(value)
	if err != nil {
		data = []byte(`{"status":"error","reason":"invalid_request","message":"查询请求格式无效。"}`)
	}
	fmt.Println(string(data))
}
