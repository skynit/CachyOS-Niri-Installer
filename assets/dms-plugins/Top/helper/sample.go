package main

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type gpuStatic struct {
	dir    string
	vendor string
	name   string
	hwmon  string
}

type staticInfo struct {
	cpuName   string
	pageSize  int64
	maxFreqs  []uint64
	coreKinds []string
	cpuTemp   []string
	gpu       *gpuStatic
	raplDir   string
	raplMax   uint64
	battery   string
}

type sampler struct {
	interval time.Duration
	topN     int
	sortBy   string
	idx      *desktopIndex
	static   staticInfo

	prevCPU    []cpuTimes
	prevNet    map[string]netCounters
	prevNetAt  time.Time
	prevDiskR  uint64
	prevDiskW  uint64
	prevDiskAt time.Time
	prevRAPL   uint64
	prevRAPLAt time.Time
	prevProcs  map[int]uint64
	exeCache   map[int]string

	now func() time.Time
}

func newSampler(interval time.Duration, topN int, sortBy string) *sampler {
	if sortBy != "mem" {
		sortBy = "cpu"
	}
	return &sampler{
		interval:  interval,
		topN:      topN,
		sortBy:    sortBy,
		idx:       loadDesktopIndex(),
		prevProcs: make(map[int]uint64),
		exeCache:  make(map[int]string),
		now:       time.Now,
		static:    probeStatic(),
	}
}

// prime takes the first counter reading so the first emitted sample has
// meaningful deltas instead of a spike.
func (s *sampler) prime() {
	s.prevCPU = readCPUStat()
	s.prevNet = readNetDev()
	s.prevNetAt = s.now()
	s.prevDiskR, s.prevDiskW = readDiskBytes()
	s.prevDiskAt = s.now()
	s.prevRAPL, s.prevRAPLAt = readRAPL(s.static.raplDir)
	for _, p := range readProcStats() {
		s.prevProcs[p.pid] = p.ticks
	}
}

func (s *sampler) sample() Snapshot {
	now := s.now()
	elapsed := now.Sub(s.prevNetAt).Seconds()
	if elapsed <= 0 {
		elapsed = s.interval.Seconds()
	}

	snap := Snapshot{TS: now.UnixMilli(), Interval: int(s.interval / time.Millisecond)}
	cpu, totalTicks := s.readCPU()
	snap.CPU = cpu
	snap.Mem = readMem()
	snap.Net = s.readNet(elapsed)
	snap.Disk = s.readDiskRates(elapsed)
	snap.GPU = s.readGPU()
	snap.Power = s.readPower(elapsed)
	snap.Battery = readBattery(s.static.battery)
	snap.Procs = s.readProcs(totalTicks)
	if load, ok := parseLoadAvg(readFileString("/proc/loadavg")); ok {
		snap.Load1 = load
	}
	if uptime, ok := parseUptime(readFileString("/proc/uptime")); ok {
		snap.UptimeSec = uptime
	}

	s.prevNetAt = now
	s.prevDiskAt = now
	return snap
}

// readCPU returns the aggregate + per-core CPU state and the aggregate jiffy
// delta, which process percentages are normalized against.
func (s *sampler) readCPU() (CPU, uint64) {
	cur := readCPUStat()
	cpu := CPU{Name: s.static.cpuName}
	if len(cur) == 0 {
		s.prevCPU = cur
		return cpu, 0
	}

	var totalDelta uint64
	if len(s.prevCPU) == len(cur) {
		totalDelta = delta(cur[0].total, s.prevCPU[0].total)
		if d := delta(cur[0].total, s.prevCPU[0].total); d > 0 {
			idle := delta(cur[0].idle, s.prevCPU[0].idle)
			cpu.Usage = clampPercent(float64(d-idle) / float64(d) * 100)
		}
	}

	freqs := readCoreFreqs(len(cur) - 1)
	cpu.Cores = make([]Core, 0, len(cur)-1)
	for i := 1; i < len(cur); i++ {
		core := Core{Index: i - 1}
		if len(s.prevCPU) == len(cur) && i < len(s.prevCPU) {
			d := delta(cur[i].total, s.prevCPU[i].total)
			if d > 0 {
				idle := delta(cur[i].idle, s.prevCPU[i].idle)
				core.Usage = clampPercent(float64(d-idle) / float64(d) * 100)
			}
		}
		if i-1 < len(freqs) && freqs[i-1] > 0 {
			mhz := float64(freqs[i-1]) / 1000
			core.Freq = &mhz
		}
		if i-1 < len(s.static.coreKinds) {
			core.Kind = s.static.coreKinds[i-1]
		}
		if i-1 < len(s.static.maxFreqs) && s.static.maxFreqs[i-1] > 0 {
			core.Max = float64(s.static.maxFreqs[i-1]) / 1000
		}
		cpu.Cores = append(cpu.Cores, core)
	}
	if temp, ok := readCPUTemp(s.static.cpuTemp); ok {
		cpu.Temp = &temp
	}

	s.prevCPU = cur
	return cpu, totalDelta
}

func (s *sampler) readNet(elapsed float64) Net {
	cur := readNetDev()
	route := readDefaultRoute()
	var out Net
	if cur == nil {
		return out
	}

	var iface string
	if route != "" {
		if _, ok := cur[route]; ok {
			iface = route
		}
	}
	if iface == "" {
		var bestTotal uint64
		for name, c := range cur {
			if name == "lo" || strings.HasPrefix(name, "docker") || strings.HasPrefix(name, "veth") {
				continue
			}
			if total := c.rx + c.tx; total > bestTotal {
				bestTotal, iface = total, name
			}
		}
	}
	if iface == "" {
		for name := range cur {
			if name != "lo" {
				iface = name
				break
			}
		}
	}
	if iface == "" {
		return out
	}

	c := cur[iface]
	out.Iface = iface
	out.RxTotal, out.TxTotal = c.rx, c.tx
	if prev, ok := s.prevNet[iface]; ok && elapsed > 0 {
		out.Rx = float64(delta(c.rx, prev.rx)) / elapsed
		out.Tx = float64(delta(c.tx, prev.tx)) / elapsed
	}
	s.prevNet = cur
	return out
}

func (s *sampler) readDiskRates(elapsed float64) Rate {
	r, w := readDiskBytes()
	out := Rate{}
	if elapsed > 0 {
		out.Read = float64(delta(r, s.prevDiskR)) / elapsed
		out.Write = float64(delta(w, s.prevDiskW)) / elapsed
	}
	s.prevDiskR, s.prevDiskW = r, w
	return out
}

func (s *sampler) readGPU() *GPU {
	g := s.static.gpu
	if g == nil {
		return nil
	}
	out := &GPU{Name: g.name, Vendor: g.vendor}
	if v, ok := readNumber(filepath.Join(g.dir, "gpu_busy_percent")); ok {
		usage := clampPercent(v)
		out.Usage = &usage
	}
	if g.hwmon != "" {
		if v, ok := readNumber(filepath.Join(g.hwmon, "temp1_input")); ok {
			temp := v / 1000
			out.Temp = &temp
		}
		if v, ok := readNumber(filepath.Join(g.hwmon, "power1_average")); ok {
			power := v / 1e6
			out.Power = &power
		}
		if v, ok := readNumber(filepath.Join(g.hwmon, "freq1_input")); ok {
			mhz := v / 1e6
			out.Freq = &mhz
		}
	}
	if v, ok := readNumber(filepath.Join(g.dir, "mem_info_vram_used")); ok {
		kb := int64(v / 1024)
		out.MemUsedKB = &kb
	}
	if v, ok := readNumber(filepath.Join(g.dir, "mem_info_vram_total")); ok {
		kb := int64(v / 1024)
		out.MemTotalKB = &kb
	}
	return out
}

func (s *sampler) readPower(elapsed float64) *Power {
	if s.static.raplDir == "" {
		return nil
	}
	energy, at := readRAPL(s.static.raplDir)
	if at.IsZero() {
		return nil
	}
	if s.prevRAPLAt.IsZero() || !at.After(s.prevRAPLAt) {
		s.prevRAPL, s.prevRAPLAt = energy, at
		return nil
	}
	dt := at.Sub(s.prevRAPLAt).Seconds()
	if dt <= 0 {
		return nil
	}
	d := delta(energy, s.prevRAPL)
	if s.static.raplMax > 0 && energy < s.prevRAPL {
		d = energy + s.static.raplMax - s.prevRAPL
	}
	s.prevRAPL, s.prevRAPLAt = energy, at
	watts := float64(d) / dt / 1e6
	if watts < 0 || watts > 500 {
		return nil
	}
	return &Power{Pkg: &watts}
}

func (s *sampler) readProcs(totalTicks uint64) []Proc {
	stats := readProcStats()
	type group struct {
		name  string
		icon  string
		cpu   float64
		memKB int64
		count int
	}
	groups := make(map[string]*group)
	seen := make(map[int]uint64, len(stats))

	for _, p := range stats {
		if p.ppid == 2 { // kthreadd children: kworkers, irq/*, migration/*, rcu/*
			continue
		}
		prev, known := s.prevProcs[p.pid]
		seen[p.pid] = p.ticks
		var procTicks uint64
		if known && p.ticks > prev {
			procTicks = p.ticks - prev
		}

		exeBase, cached := s.exeCache[p.pid]
		if !cached {
			if exe, err := os.Readlink(filepath.Join("/proc", strconv.Itoa(p.pid), "exe")); err == nil {
				exeBase = filepath.Base(strings.TrimSuffix(exe, " (deleted)"))
			}
			s.exeCache[p.pid] = exeBase
		}
		entry, matched := s.idx.lookup(exeBase, p.comm)

		key, name, icon := "exe:"+exeBase, p.comm, ""
		if matched {
			key, name, icon = "app:"+strings.ToLower(entry.name), entry.name, entry.icon
		} else if exeBase != "" {
			name = exeBase
		}
		if key == "exe:" {
			key = "comm:" + p.comm
		}

		g := groups[key]
		if g == nil {
			g = &group{name: name, icon: icon}
			groups[key] = g
		}
		if procTicks > 0 && totalTicks > 0 {
			g.cpu += float64(procTicks) / float64(totalTicks) * 100
		}
		g.memKB += p.rssPages * s.static.pageSize / 1024
		g.count++
	}
	s.prevProcs = seen
	for pid := range s.exeCache {
		if _, ok := seen[pid]; !ok {
			delete(s.exeCache, pid)
		}
	}

	rows := make([]Proc, 0, len(groups))
	for _, g := range groups {
		if g.cpu < 0.05 && g.memKB < 32*1024 { // idle noise, not an app row
			continue
		}
		rows = append(rows, Proc{Name: g.name, Icon: g.icon, CPU: clampPercent(g.cpu), MemKB: g.memKB, Count: g.count})
	}
	if s.sortBy == "mem" {
		sort.Slice(rows, func(i, j int) bool {
			if rows[i].MemKB != rows[j].MemKB {
				return rows[i].MemKB > rows[j].MemKB
			}
			if rows[i].CPU != rows[j].CPU {
				return rows[i].CPU > rows[j].CPU
			}
			return rows[i].Name < rows[j].Name
		})
	} else {
		sort.Slice(rows, func(i, j int) bool {
			if rows[i].CPU != rows[j].CPU {
				return rows[i].CPU > rows[j].CPU
			}
			if rows[i].MemKB != rows[j].MemKB {
				return rows[i].MemKB > rows[j].MemKB
			}
			return rows[i].Name < rows[j].Name
		})
	}
	if s.topN > 0 && len(rows) > s.topN {
		rows = rows[:s.topN]
	}
	return rows
}

// ---- /proc and /sys readers ----

func readFileString(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(data)
}

func readNumber(path string) (float64, bool) {
	s := strings.TrimSpace(readFileString(path))
	if s == "" {
		return 0, false
	}
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

func readCPUStat() []cpuTimes { return parseCPUStat(readFileString("/proc/stat")) }

func readNetDev() map[string]netCounters { return parseNetDev(readFileString("/proc/net/dev")) }

func readDefaultRoute() string { return parseDefaultRoute(readFileString("/proc/net/route")) }

func readDiskBytes() (uint64, uint64) {
	return parseDiskstats(readFileString("/proc/diskstats"))
}

func readProcStats() []procStat {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	out := make([]procStat, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() || e.Name() == "" || e.Name()[0] < '0' || e.Name()[0] > '9' {
			continue
		}
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		stat, err := parseProcStat(readFileString(filepath.Join("/proc", e.Name(), "stat")))
		if err != nil {
			continue
		}
		stat.pid = pid
		out = append(out, stat)
	}
	return out
}

func readMem() Mem {
	mi := parseMeminfo(readFileString("/proc/meminfo"))
	m := Mem{
		TotalKB:      mi["MemTotal"],
		AvailableKB:  mi["MemAvailable"],
		CachedKB:     mi["Cached"],
		SwapTotalKB:  mi["SwapTotal"],
		SwapUsedKB:   mi["SwapTotal"] - mi["SwapFree"],
		CompressedKB: zramCompressedKB(),
	}
	if m.AvailableKB == 0 {
		m.AvailableKB = mi["MemFree"] + mi["Buffers"] + mi["Cached"]
	}
	m.UsedKB = m.TotalKB - m.AvailableKB
	if m.UsedKB < 0 {
		m.UsedKB = 0
	}
	if avg, ok := parsePressure(readFileString("/proc/pressure/memory")); ok {
		m.PressureAvg10 = avg
		switch {
		case avg < 10:
			m.Pressure = "normal"
		case avg < 40:
			m.Pressure = "elevated"
		default:
			m.Pressure = "critical"
		}
	}
	return m
}

func zramCompressedKB() int64 {
	matches, _ := filepath.Glob("/sys/block/zram*/mm_stat")
	var total int64
	for _, path := range matches {
		fields := strings.Fields(readFileString(path))
		if len(fields) < 2 {
			continue
		}
		if v, err := strconv.ParseInt(fields[1], 10, 64); err == nil {
			total += v / 1024
		}
	}
	return total
}

func readCPUModel() string {
	for _, line := range strings.Split(readFileString("/proc/cpuinfo"), "\n") {
		if strings.HasPrefix(line, "model name") {
			if _, value, ok := strings.Cut(line, ":"); ok {
				return strings.TrimSpace(value)
			}
		}
	}
	return ""
}

func cpuSysPath(n int) string {
	return filepath.Join("/sys/devices/system/cpu", "cpu"+strconv.Itoa(n))
}

func readMaxFreqs() []uint64 {
	entries, _ := filepath.Glob("/sys/devices/system/cpu/cpu[0-9]*")
	out := make([]uint64, len(entries))
	for i := range entries {
		if v, ok := readNumber(filepath.Join(cpuSysPath(i), "cpufreq", "cpuinfo_max_freq")); ok {
			out[i] = uint64(v)
		}
	}
	return out
}

func readCoreFreqs(n int) []uint64 {
	out := make([]uint64, n)
	for i := 0; i < n; i++ {
		if v, ok := readNumber(filepath.Join(cpuSysPath(i), "cpufreq", "scaling_cur_freq")); ok {
			out[i] = uint64(v)
		}
	}
	return out
}

func readCPUTemp(paths []string) (float64, bool) {
	var best float64
	found := false
	for _, path := range paths {
		if v, ok := readNumber(path); ok && v > 0 {
			c := v / 1000
			if !found || c > best {
				best = c
			}
			found = true
		}
	}
	return best, found
}

func probeStatic() staticInfo {
	info := staticInfo{pageSize: int64(os.Getpagesize())}
	info.cpuName = readCPUModel()
	info.maxFreqs = readMaxFreqs()
	info.coreKinds = classifyCores(info.maxFreqs)
	info.cpuTemp = probeCPUTemp()
	info.gpu = probeGPU()
	info.raplDir, info.raplMax = probeRAPL()
	info.battery = probeBattery()
	return info
}

func probeCPUTemp() []string {
	names := map[string]bool{"k10temp": true, "coretemp": true, "zenpower": true, "cpu_thermal": true, "soc_thermal": true}
	matches, _ := filepath.Glob("/sys/class/hwmon/hwmon*")
	var out []string
	for _, dir := range matches {
		name := strings.TrimSpace(readFileString(filepath.Join(dir, "name")))
		if names[name] {
			out = append(out, filepath.Join(dir, "temp1_input"))
		}
	}
	if len(out) == 0 {
		out = append(out, "/sys/class/hwmon/hwmon0/temp1_input")
	}
	return out
}

func probeGPU() *gpuStatic {
	matches, _ := filepath.Glob("/sys/class/drm/card[0-9]*/device")
	for _, dir := range matches {
		vendor := strings.TrimSpace(readFileString(filepath.Join(dir, "vendor")))
		name := ""
		switch vendor {
		case "0x1002":
			name = "AMD GPU"
		case "0x10de":
			name = "NVIDIA GPU"
		case "0x8086":
			name = "Intel GPU"
		default:
			continue
		}
		hwmons, _ := filepath.Glob(filepath.Join(dir, "hwmon", "hwmon*"))
		hwmon := ""
		if len(hwmons) > 0 {
			hwmon = hwmons[0]
		}
		return &gpuStatic{dir: dir, vendor: strings.TrimPrefix(vendor, "0x"), name: name, hwmon: hwmon}
	}
	return nil
}

func probeRAPL() (string, uint64) {
	matches, _ := filepath.Glob("/sys/class/powercap/intel-rapl:*/name")
	for _, namePath := range matches {
		if strings.TrimSpace(readFileString(namePath)) != "package-0" {
			continue
		}
		dir := filepath.Dir(namePath)
		var max uint64
		if v, ok := readNumber(filepath.Join(dir, "max_energy_range_uj")); ok {
			max = uint64(v)
		}
		return dir, max
	}
	return "", 0
}

func readRAPL(dir string) (uint64, time.Time) {
	if dir == "" {
		return 0, time.Time{}
	}
	v, ok := readNumber(filepath.Join(dir, "energy_uj"))
	if !ok {
		return 0, time.Time{}
	}
	return uint64(v), time.Now()
}

func probeBattery() string {
	matches, _ := filepath.Glob("/sys/class/power_supply/BAT*")
	if len(matches) == 0 {
		return ""
	}
	return matches[0]
}

func readBattery(dir string) *Batt {
	if dir == "" {
		return nil
	}
	b := &Batt{}
	if v, ok := readNumber(filepath.Join(dir, "capacity")); ok {
		b.Percent = &v
	}
	b.Status = strings.ToLower(strings.TrimSpace(readFileString(filepath.Join(dir, "status"))))
	if v, ok := readNumber(filepath.Join(dir, "power_now")); ok {
		w := v / 1e6
		b.Power = &w
	} else if cur, ok1 := readNumber(filepath.Join(dir, "current_now")); ok1 {
		if volt, ok2 := readNumber(filepath.Join(dir, "voltage_now")); ok2 {
			w := cur * volt / 1e12
			b.Power = &w
		}
	}
	return b
}

// ---- helpers ----

func delta(cur, prev uint64) uint64 {
	if cur >= prev {
		return cur - prev
	}
	return 0
}

func clampPercent(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}
