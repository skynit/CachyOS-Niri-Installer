package main

import (
	"bufio"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type cpuTimes struct {
	total uint64
	idle  uint64
}

type netCounters struct {
	rx uint64
	tx uint64
}

type procStat struct {
	pid      int
	ppid     int
	ticks    uint64
	rssPages int64
	comm     string
}

// parseCPUStat parses /proc/stat. Index 0 is the aggregate "cpu" line,
// index n+1 is "cpuN".
func parseCPUStat(s string) []cpuTimes {
	var out []cpuTimes
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "cpu") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}
		var t cpuTimes
		for i, f := range fields[1:] {
			if i > 7 {
				break // guest fields are already included in user/nice
			}
			v, _ := strconv.ParseUint(f, 10, 64)
			t.total += v
			if i == 3 || i == 4 { // idle + iowait
				t.idle += v
			}
		}
		out = append(out, t)
	}
	return out
}

// parseLoadAvg returns the 1-minute load average of /proc/loadavg.
func parseLoadAvg(s string) (float64, bool) {
	fields := strings.Fields(s)
	if len(fields) == 0 {
		return 0, false
	}
	v, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

// parseUptime returns whole seconds from /proc/uptime.
func parseUptime(s string) (int64, bool) {
	fields := strings.Fields(s)
	if len(fields) == 0 {
		return 0, false
	}
	v, err := strconv.ParseFloat(fields[0], 64)
	if err != nil || v < 0 {
		return 0, false
	}
	return int64(v), true
}

// parseMeminfo parses /proc/meminfo into a key/value map in kB.
func parseMeminfo(s string) map[string]int64 {
	out := make(map[string]int64)
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		line := sc.Text()
		i := strings.IndexByte(line, ':')
		if i < 0 {
			continue
		}
		fields := strings.Fields(line[i+1:])
		if len(fields) == 0 {
			continue
		}
		v, err := strconv.ParseInt(fields[0], 10, 64)
		if err != nil {
			continue
		}
		out[line[:i]] = v
	}
	return out
}

// parsePressure returns the "some avg10" value of /proc/pressure/memory.
func parsePressure(s string) (float64, bool) {
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "some ") {
			continue
		}
		for _, f := range strings.Fields(line) {
			if v, ok := strings.CutPrefix(f, "avg10="); ok {
				parsed, err := strconv.ParseFloat(v, 64)
				if err == nil {
					return parsed, true
				}
			}
		}
	}
	return 0, false
}

// parseNetDev parses /proc/net/dev into per-interface byte counters.
func parseNetDev(s string) map[string]netCounters {
	out := make(map[string]netCounters)
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		line := sc.Text()
		i := strings.IndexByte(line, ':')
		if i < 0 {
			continue
		}
		name := strings.TrimSpace(line[:i])
		if name == "" || strings.Contains(name, "|") {
			continue
		}
		fields := strings.Fields(line[i+1:])
		if len(fields) < 9 {
			continue
		}
		rx, err1 := strconv.ParseUint(fields[0], 10, 64)
		tx, err2 := strconv.ParseUint(fields[8], 10, 64)
		if err1 != nil || err2 != nil {
			continue
		}
		out[name] = netCounters{rx: rx, tx: tx}
	}
	return out
}

// parseDefaultRoute returns the interface carrying the default route.
func parseDefaultRoute(s string) string {
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		// Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT
		if len(fields) < 8 || fields[1] != "00000000" {
			continue
		}
		if iface := fields[0]; iface != "" && iface != "lo" {
			return iface
		}
	}
	return ""
}

// parseDiskstats sums sectors read/written by whole block devices.
func parseDiskstats(s string) (readBytes, writeBytes uint64) {
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 10 {
			continue
		}
		name := fields[2]
		if !isWholeDisk(name) {
			continue
		}
		rs, err1 := strconv.ParseUint(fields[5], 10, 64)
		ws, err2 := strconv.ParseUint(fields[9], 10, 64)
		if err1 != nil || err2 != nil {
			continue
		}
		readBytes += rs * 512
		writeBytes += ws * 512
	}
	return readBytes, writeBytes
}

var partitionPattern = regexp.MustCompile(`^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+)\d+$|^(nvme\d+n\d+|mmcblk\d+)p\d+$`)

func isWholeDisk(name string) bool {
	for _, prefix := range []string{"loop", "ram", "zram", "sr", "dm-", "md", "nbd", "fd"} {
		if strings.HasPrefix(name, prefix) {
			return false
		}
	}
	return !partitionPattern.MatchString(name)
}

// parseProcStat parses /proc/<pid>/stat, tolerating spaces and parentheses
// inside the process name.
func parseProcStat(s string) (procStat, error) {
	l := strings.IndexByte(s, '(')
	r := strings.LastIndexByte(s, ')')
	if l < 0 || r < l {
		return procStat{}, strconv.ErrSyntax
	}
	st := procStat{comm: s[l+1 : r]}
	fields := strings.Fields(s[r+1:])
	// state(3) ppid(4) ... utime(14) stime(15) ... rss(24)
	if len(fields) < 22 {
		return procStat{}, strconv.ErrSyntax
	}
	pid, err := strconv.Atoi(strings.TrimSpace(s[:l]))
	if err != nil {
		return procStat{}, err
	}
	ppid, err := strconv.Atoi(fields[1])
	if err != nil {
		return procStat{}, err
	}
	utime, err1 := strconv.ParseUint(fields[11], 10, 64)
	stime, err2 := strconv.ParseUint(fields[12], 10, 64)
	rss, err3 := strconv.ParseInt(fields[21], 10, 64)
	if err1 != nil || err2 != nil || err3 != nil {
		return procStat{}, strconv.ErrSyntax
	}
	st.pid = pid
	st.ppid = ppid
	st.ticks = utime + stime
	st.rssPages = rss
	return st, nil
}

// classifyCores groups identical-frequency clusters into "P" (fast) and
// "E" (slow) only when the CPU is actually hybrid.
func classifyCores(maxFreqKHz []uint64) []string {
	kinds := make([]string, len(maxFreqKHz))
	var maximum, minimum uint64
	for _, f := range maxFreqKHz {
		if f == 0 {
			continue
		}
		if maximum == 0 || f > maximum {
			maximum = f
		}
		if minimum == 0 || f < minimum {
			minimum = f
		}
	}
	if maximum == 0 || minimum == 0 || maximum*100 < minimum*115 {
		return kinds
	}
	threshold := maximum - (maximum-minimum)/3
	for i, f := range maxFreqKHz {
		switch {
		case f >= threshold:
			kinds[i] = "P"
		case f > 0:
			kinds[i] = "E"
		}
	}
	return kinds
}

// uniqueSortedFreqs returns distinct non-zero max frequencies, ascending.
func uniqueSortedFreqs(freqs []uint64) []uint64 {
	seen := make(map[uint64]bool)
	var out []uint64
	for _, f := range freqs {
		if f == 0 || seen[f] {
			continue
		}
		seen[f] = true
		out = append(out, f)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// splitExec extracts the command basename and, for flatpak, the application id.
func splitExec(exec string) (base, appID string) {
	fields := strings.Fields(exec)
	for len(fields) > 0 && (fields[0] == "env" || strings.Contains(fields[0], "=")) {
		fields = fields[1:]
	}
	if len(fields) == 0 {
		return "", ""
	}
	cmd := strings.Trim(fields[0], `"'`)
	base = filepath.Base(cmd)
	if base == "flatpak" {
		for i := 1; i < len(fields); i++ {
			if fields[i] == "run" && i+1 < len(fields) {
				return base, strings.Trim(fields[i+1], `"'`)
			}
		}
	}
	return base, ""
}
