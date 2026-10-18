package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const maxBytes = 1024 * 1024
const maxLines = 5000

var stamp = regexp.MustCompile(`\[(\d{1,4}):([0-5]\d)(?:[.:](\d{1,3}))?\]`)
var metadata = regexp.MustCompile(`(?i)^\[(?:ar|al|ti|au|by|re|ve|length|offset):.*\]$`)
var offsetTag = regexp.MustCompile(`(?i)\[offset:([+-]?\d+)\]`)
var wordTime = regexp.MustCompile(`<\d{1,4}:[0-5]\d(?:[.:]\d{1,3})?>`)

type request struct {
	Title    string  `json:"title"`
	Artist   string  `json:"artist"`
	Album    string  `json:"album"`
	URL      string  `json:"url"`
	Player   string  `json:"player"`
	Duration float64 `json:"duration"`
}

type line struct {
	Time *float64 `json:"time"`
	Text string   `json:"text"`
}

type result struct {
	Status  string `json:"status"`
	Reason  string `json:"reason,omitempty"`
	Message string `json:"message,omitempty"`
	Lines   []line `json:"lines"`
	Path    string `json:"path,omitempty"`
	Source  string `json:"source,omitempty"`
}

func fail(reason, message string) result {
	return result{Status: "error", Reason: reason, Message: message, Lines: []line{}}
}

func parse(text string) (result, error) {
	offsets := offsetTag.FindAllStringSubmatch(text, -1)
	offset := 0.0
	if len(offsets) > 0 {
		milliseconds, err := strconv.Atoi(offsets[len(offsets)-1][1])
		if err != nil {
			return result{}, err
		}
		offset = float64(milliseconds) / 1000
	}
	timed := make(map[float64][]string)
	plain := []line{}
	for _, raw := range strings.Split(text, "\n") {
		value := strings.TrimSpace(raw)
		if value == "" || metadata.MatchString(value) {
			continue
		}
		matches := stamp.FindAllStringSubmatchIndex(value, -1)
		if len(matches) == 0 || matches[0][0] != 0 {
			plain = append(plain, line{Text: value})
			continue
		}
		content := strings.TrimSpace(wordTime.ReplaceAllString(stamp.ReplaceAllString(value, ""), ""))
		for _, match := range matches {
			minutes, _ := strconv.Atoi(value[match[2]:match[3]])
			seconds, _ := strconv.Atoi(value[match[4]:match[5]])
			fraction := 0.0
			if match[6] >= 0 {
				fraction, _ = strconv.ParseFloat("0."+value[match[6]:match[7]], 64)
			}
			at := math.RoundToEven((float64(minutes*60+seconds)+fraction-offset)*1000) / 1000
			if !slices.Contains(timed[at], content) {
				timed[at] = append(timed[at], content)
			}
		}
		if len(timed) > maxLines {
			return result{}, errors.New("歌词行数超过 5000 行。")
		}
	}
	if len(timed) > 0 {
		keys := make([]float64, 0, len(timed))
		for at := range timed {
			keys = append(keys, at)
		}
		sort.Float64s(keys)
		lines := make([]line, 0, len(keys))
		for _, at := range keys {
			var values []string
			for _, value := range timed[at] {
				if value != "" {
					values = append(values, value)
				}
			}
			lines = append(lines, line{Time: &at, Text: strings.Join(values, "\n")})
		}
		return result{Status: "synced", Lines: lines}, nil
	}
	if len(plain) > maxLines {
		return result{}, errors.New("歌词行数超过 5000 行。")
	}
	if len(plain) > 0 {
		return result{Status: "plain", Lines: plain}, nil
	}
	return result{Status: "empty", Reason: "empty_lyrics", Message: "内嵌歌词没有可显示的内容。", Lines: []line{}}, nil
}

func songPath(r request) (string, error) {
	uri, err := url.Parse(r.URL)
	if err != nil {
		return "", errors.New("当前歌曲不是本地文件，无法离线读取内嵌歌词。")
	}
	if uri.Scheme == "file" && (uri.Host == "" || uri.Host == "localhost") && filepath.IsAbs(uri.Path) {
		return uri.Path, nil
	}
	if uri.Scheme != "" {
		return "", errors.New("当前歌曲不是本地文件，无法离线读取内嵌歌词。")
	}
	if !strings.Contains(strings.ToLower(r.Player), "termusic") {
		return "", errors.New("播放器未提供本地歌曲路径，无法读取内嵌歌词。")
	}
	if r.Title == "" || r.Artist == "" {
		return "", errors.New("termusic 尚未提供完整的歌名和歌手信息。")
	}
	config := os.Getenv("XDG_CONFIG_HOME")
	if config == "" {
		home, _ := os.UserHomeDir()
		config = filepath.Join(home, ".config")
	}
	library := filepath.Join(config, "termusic", "library2.db")
	if info, err := os.Stat(library); err != nil || !info.Mode().IsRegular() {
		return "", errors.New("找不到 termusic 本地媒体库，请先在 termusic 中扫描歌曲。")
	}
	dsn := url.URL{Scheme: "file", Path: library, RawQuery: "mode=ro"}
	db, err := sql.Open("sqlite", dsn.String())
	if err != nil {
		return "", err
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	rows, err := db.QueryContext(ctx, `SELECT t.file_dir, t.file_stem, t.file_ext, t.duration, a.title AS album
		FROM tracks t JOIN tracks_metadata m ON m.track = t.id LEFT JOIN albums a ON a.id = t.album
		WHERE m.title = ? AND m.artist_display = ?`, r.Title, r.Artist)
	if err != nil {
		return "", err
	}
	type track struct {
		path, album string
		duration    sql.NullFloat64
	}
	var tracks []track
	for rows.Next() {
		var dir, stem, ext string
		var album sql.NullString
		var duration sql.NullFloat64
		if err := rows.Scan(&dir, &stem, &ext, &duration, &album); err != nil {
			rows.Close()
			return "", err
		}
		tracks = append(tracks, track{path: filepath.Join(dir, stem+"."+ext), album: album.String, duration: duration})
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return "", err
	}
	if len(tracks) > 1 && r.Album != "" {
		var filtered []track
		for _, item := range tracks {
			if item.album == r.Album {
				filtered = append(filtered, item)
			}
		}
		if len(filtered) > 0 {
			tracks = filtered
		}
	}
	if len(tracks) > 1 && r.Duration > 0 {
		var filtered []track
		for _, item := range tracks {
			if item.duration.Valid && math.Abs(item.duration.Float64-r.Duration) <= 2 {
				filtered = append(filtered, item)
			}
		}
		if len(filtered) > 0 {
			tracks = filtered
		}
	}
	unique := map[string]bool{}
	for _, item := range tracks {
		unique[item.path] = true
	}
	if len(unique) == 0 {
		return "", errors.New("termusic 媒体库中未找到匹配的歌曲，请重新扫描媒体库。")
	}
	if len(unique) > 1 {
		return "", errors.New("媒体库中有多个同名版本，无法确定当前歌曲文件。")
	}
	for path := range unique {
		return path, nil
	}
	return "", errors.New("媒体库中未找到歌曲。")
}

func embedded(path string) ([]string, error) {
	allowed := []string{".flac", ".mp3", ".m4a", ".mp4", ".ogg", ".opus", ".wav", ".wma", ".aac", ".ape", ".wv", ".aiff", ".aif"}
	if !slices.Contains(allowed, strings.ToLower(filepath.Ext(path))) {
		return nil, errors.New("不支持此音频文件格式。")
	}
	if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("歌曲文件不存在或已移动，请刷新播放器媒体库。")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ffprobe", "-v", "error", "-protocol_whitelist", "file", "-show_entries", "format_tags:stream_tags", "-of", "json", path)
	data, err := cmd.Output()
	if ctx.Err() != nil {
		return nil, errors.New("读取音频标签超时，请重试。")
	}
	if errors.Is(err, exec.ErrNotFound) {
		return nil, errors.New("请安装 FFmpeg（ffprobe），然后重新读取。")
	}
	if err != nil {
		return nil, errors.New("无法读取音频标签，请确认文件完整且格式受支持。")
	}
	if len(data) > maxBytes*4 {
		return nil, errors.New("音频标签过大，无法显示。")
	}
	var result struct {
		Format struct {
			Tags map[string]any `json:"tags"`
		} `json:"format"`
		Streams []struct {
			Tags map[string]any `json:"tags"`
		} `json:"streams"`
	}
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, err
	}
	groups := []map[string]any{result.Format.Tags}
	for _, stream := range result.Streams {
		groups = append(groups, stream.Tags)
	}
	texts := []string{}
	for _, tags := range groups {
		for name, value := range tags {
			key := strings.NewReplacer(" ", "", "_", "", "-", "").Replace(strings.ToLower(name))
			lyric, ok := value.(string)
			if !ok || strings.TrimSpace(lyric) == "" {
				continue
			}
			if strings.HasPrefix(key, "lyrics") || strings.HasPrefix(key, "unsyncedlyrics") || key == "uslt" || key == "©lyr" {
				if len(lyric) > maxBytes {
					return nil, errors.New("内嵌歌词超过 1 MiB，无法显示。")
				}
				texts = append(texts, lyric)
			}
		}
	}
	return texts, nil
}

func load(r request) result {
	if strings.TrimSpace(r.Title) == "" && !strings.HasPrefix(r.URL, "file:") {
		return result{Status: "empty", Reason: "no_track", Message: "播放器尚未提供歌曲信息。", Lines: []line{}}
	}
	path, err := songPath(r)
	if err == nil {
		var texts []string
		texts, err = embedded(path)
		if err == nil {
			var selected result
			for _, text := range texts {
				var parsed result
				parsed, err = parse(text)
				if err != nil {
					break
				}
				if parsed.Status == "synced" && selected.Status != "synced" || parsed.Status == "plain" && selected.Status == "" {
					selected = parsed
				}
				if selected.Status == "synced" {
					break
				}
			}
			if err == nil {
				if selected.Status != "" {
					selected.Path, selected.Source = path, "embedded"
					return selected
				}
				return result{Status: "empty", Reason: "no_embedded_lyrics", Message: "这首歌没有可读取的内嵌歌词。", Lines: []line{}, Path: path}
			}
		}
	}
	return fail("read_failed", "读取失败："+err.Error())
}

func main() {
	data, err := io.ReadAll(io.LimitReader(os.Stdin, 16385))
	value := result{}
	var r request
	if err == nil && len(data) <= 16384 {
		var raw map[string]json.RawMessage
		if json.Unmarshal(data, &raw) == nil && raw != nil {
			valid := true
			for _, key := range []string{"title", "artist", "album", "url", "player"} {
				if field, ok := raw[key]; ok && (string(field) == "null" || json.Unmarshal(field, new(string)) != nil) {
					valid = false
				}
			}
			if field, ok := raw["duration"]; ok && (string(field) == "null" || json.Unmarshal(field, new(float64)) != nil) {
				valid = false
			}
			if valid && json.Unmarshal(data, &r) == nil {
				value = load(r)
			} else {
				value = fail("invalid_request", "歌词请求格式无效。")
			}
		} else {
			value = fail("invalid_request", "歌词请求格式无效。")
		}
	} else {
		value = fail("invalid_request", "歌词请求格式无效。")
	}
	json.NewEncoder(os.Stdout).Encode(value)
}
