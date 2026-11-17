package main

import (
	"fmt"
	"strconv"
	"strings"
)

// This scanner records byte ranges instead of reserializing the document, so
// edits retain unrelated nodes, whitespace, comments and include declarations.
type token struct {
	text       string
	start, end int
}
type node struct {
	name                    string
	args                    []token
	start, end, open, close int
	children                []node
	disabled                bool
}
type flag struct{}

func scanKDL(s string) ([]token, error) {
	var tokens []token
	for i := 0; i < len(s); {
		start := i
		switch {
		case s[i] == ' ' || s[i] == '\t' || s[i] == '\r':
			i++
		case strings.HasPrefix(s[i:], "//"):
			for i < len(s) && s[i] != '\n' {
				i++
			}
		case strings.HasPrefix(s[i:], "/*"):
			i += 2
			depth := 1
			for i < len(s) && depth > 0 {
				if strings.HasPrefix(s[i:], "/*") {
					depth++
					i += 2
				} else if strings.HasPrefix(s[i:], "*/") {
					depth--
					i += 2
				} else {
					i++
				}
			}
			if depth != 0 {
				return nil, fmt.Errorf("未闭合的块注释")
			}
		case strings.HasPrefix(s[i:], "/-"):
			i += 2
			tokens = append(tokens, token{"/-", start, i})
		case s[i] == '\\':
			i++
			for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r') {
				i++
			}
			if i >= len(s) || s[i] != '\n' {
				return nil, fmt.Errorf("不支持的续行语法")
			}
			i++
		case s[i] == '"':
			if strings.HasPrefix(s[i:], `"""`) {
				return nil, fmt.Errorf("暂不支持 KDL 多行字符串")
			}
			i++
			closed := false
			for i < len(s) {
				if s[i] == '\\' {
					i += 2
					continue
				}
				if s[i] == '"' {
					i++
					closed = true
					break
				}
				i++
			}
			if !closed {
				return nil, fmt.Errorf("未闭合的字符串")
			}
			tokens = append(tokens, token{s[start:i], start, i})
		case s[i] == 'r' && i+1 < len(s) && (s[i+1] == '#' || s[i+1] == '"'):
			j := i + 1
			for j < len(s) && s[j] == '#' {
				j++
			}
			if j >= len(s) || s[j] != '"' {
				return nil, fmt.Errorf("不支持的原始字符串")
			}
			suffix := `"` + s[i+1:j]
			k := strings.Index(s[j+1:], suffix)
			if k < 0 {
				return nil, fmt.Errorf("未闭合的原始字符串")
			}
			i = j + 1 + k + len(suffix)
			tokens = append(tokens, token{s[start:i], start, i})
		case strings.ContainsRune("{};\n", rune(s[i])):
			i++
			tokens = append(tokens, token{s[start:i], start, i})
		default:
			for i < len(s) && !strings.ContainsRune(" \t\r\n{};\"", rune(s[i])) && !strings.HasPrefix(s[i:], "//") && !strings.HasPrefix(s[i:], "/*") {
				i++
			}
			if i == start {
				return nil, fmt.Errorf("不支持的 KDL 语法")
			}
			tokens = append(tokens, token{s[start:i], start, i})
		}
	}
	return tokens, nil
}

func parseKDL(s string) ([]node, error) {
	tokens, err := scanKDL(s)
	if err != nil {
		return nil, err
	}
	i := 0
	var parse func(bool) ([]node, error)
	parse = func(nested bool) ([]node, error) {
		var result []node
		for i < len(tokens) {
			t := tokens[i]
			if t.text == "\n" || t.text == ";" {
				i++
				continue
			}
			if t.text == "}" {
				if !nested {
					return nil, fmt.Errorf("多余的结束括号")
				}
				return result, nil
			}
			disabled := t.text == "/-"
			start := t.start
			if disabled {
				i++
				if i >= len(tokens) {
					return nil, fmt.Errorf("缺少注释节点")
				}
				t = tokens[i]
			}
			if t.text == "{" {
				return nil, fmt.Errorf("缺少节点名")
			}
			n := node{name: t.text, start: start, end: t.end, open: -1, close: -1, disabled: disabled}
			i++
			for i < len(tokens) {
				t = tokens[i]
				if t.text == "{" {
					n.open = t.start
					i++
					n.children, err = parse(true)
					if err != nil {
						return nil, err
					}
					if i >= len(tokens) || tokens[i].text != "}" {
						return nil, fmt.Errorf("未闭合的节点")
					}
					n.close = tokens[i].start
					n.end = tokens[i].end
					i++
					break
				}
				if t.text == "\n" || t.text == ";" || t.text == "}" {
					break
				}
				if t.text == "/-" {
					return nil, fmt.Errorf("节点属性注释暂不支持编辑")
				}
				n.args = append(n.args, t)
				n.end = t.end
				i++
			}
			result = append(result, n)
		}
		if nested {
			return nil, fmt.Errorf("未闭合的节点")
		}
		return result, nil
	}
	return parse(false)
}

func findNode(nodes []node, name string) (*node, error) {
	var found *node
	for i := range nodes {
		if nodes[i].disabled || nodes[i].name != name {
			continue
		}
		if found != nil {
			return nil, fmt.Errorf("存在多个 %s 节点，需要先在原配置中消除歧义", name)
		}
		found = &nodes[i]
	}
	return found, nil
}

func valueAt(nodes []node, path []string) (any, bool, error) {
	n, err := findNode(nodes, path[0])
	if err != nil || n == nil {
		return nil, false, err
	}
	if len(path) > 1 {
		return valueAt(n.children, path[1:])
	}
	if len(n.args) == 0 {
		return true, true, nil
	}
	if len(n.args) != 1 {
		return nil, false, fmt.Errorf("%s 不是单值设置", n.name)
	}
	v := n.args[0].text
	if v == "true" || v == "false" {
		return v == "true", true, nil
	}
	if strings.HasPrefix(v, `"`) {
		x, e := strconv.Unquote(v)
		return x, e == nil, e
	}
	f, e := strconv.ParseFloat(v, 64)
	return f, e == nil, e
}

func editKDL(src string, path []string, value any) (string, error) {
	nodes, err := parseKDL(src)
	if err != nil {
		return "", err
	}
	return editNodes(src, nodes, path, value, 0)
}

func editNodes(src string, nodes []node, path []string, value any, depth int) (string, error) {
	n, err := findNode(nodes, path[0])
	if err != nil {
		return "", err
	}
	indent := strings.Repeat("    ", depth)
	if n == nil {
		if value == nil {
			return src, nil
		}
		var entry string
		if len(path) == 1 {
			entry = indent + path[0] + kdlValue(value) + "\n"
		} else {
			child, e := editNodes("", nil, path[1:], value, depth+1)
			if e != nil {
				return "", e
			}
			entry = indent + path[0] + " {\n" + child + indent + "}\n"
		}
		return src + "\n" + entry, nil
	}
	if len(path) > 1 {
		if n.open < 0 {
			return "", fmt.Errorf("%s 缺少子节点", n.name)
		}
		body := src[n.open+1 : n.close]
		child, e := editKDL(body, path[1:], value)
		if e != nil {
			return "", e
		}
		// Newly inserted nodes use the current nesting indentation.
		if child != body && strings.HasPrefix(child, body+"\n") {
			child = body + "\n" + indentLines(strings.TrimPrefix(child, body+"\n"), depth+1)
		}
		return src[:n.open+1] + child + src[n.close:], nil
	}
	if n.open >= 0 {
		return "", fmt.Errorf("%s 包含子节点，不能按单值改写", n.name)
	}
	if len(n.args) > 1 {
		return "", fmt.Errorf("%s 包含额外属性，不能安全改写", n.name)
	}
	if value == nil {
		return src[:n.start] + src[nodeEnd(src, *n):], nil
	}
	return src[:n.start] + n.name + kdlValue(value) + src[n.end:], nil
}

func nodeEnd(src string, n node) int {
	end := n.end
	for end < len(src) && (src[end] == ' ' || src[end] == '\t') {
		end++
	}
	if end < len(src) && src[end] == ';' {
		return end + 1
	}
	return n.end
}

func indentLines(s string, depth int) string {
	prefix := strings.Repeat("    ", depth)
	lines := strings.SplitAfter(s, "\n")
	for i := range lines {
		if strings.TrimSpace(lines[i]) != "" {
			lines[i] = prefix + lines[i]
		}
	}
	return strings.Join(lines, "")
}

func kdlValue(value any) string {
	switch v := value.(type) {
	case flag:
		return ""
	case string:
		return " " + strconv.Quote(v)
	case bool:
		return " " + strconv.FormatBool(v)
	case float64:
		return " " + strconv.FormatFloat(v, 'f', -1, 64)
	}
	panic("unvalidated KDL value")
}
