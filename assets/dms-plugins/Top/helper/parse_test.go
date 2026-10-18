package main

import (
	"encoding/json"
	"testing"
)

func TestParseCPUStat(t *testing.T) {
	s := `cpu  100 20 30 400 50 6 7 8 0 0
cpu0 50 10 15 200 25 3 3 4 0 0
cpu1 50 10 15 200 25 3 4 4 0 0
intr 1 2 3
`
	got := parseCPUStat(s)
	if len(got) != 3 {
		t.Fatalf("got %d entries, want 3", len(got))
	}
	if got[0].total != 621 {
		t.Errorf("aggregate total = %d, want 621", got[0].total)
	}
	if got[0].idle != 450 {
		t.Errorf("aggregate idle = %d, want 450", got[0].idle)
	}
	if got[1].total != 310 {
		t.Errorf("cpu0 total = %d, want 310", got[1].total)
	}
}

func TestParseMeminfo(t *testing.T) {
	s := `MemTotal:       31984368 kB
MemFree:         3269132 kB
MemAvailable:   18302756 kB
SwapTotal:      50331640 kB
SwapFree:       50329176 kB
`
	got := parseMeminfo(s)
	if got["MemTotal"] != 31984368 {
		t.Errorf("MemTotal = %d", got["MemTotal"])
	}
	if got["SwapFree"] != 50329176 {
		t.Errorf("SwapFree = %d", got["SwapFree"])
	}
}

func TestParsePressure(t *testing.T) {
	s := "some avg10=0.02 avg60=0.41 avg300=0.18 total=1607065\nfull avg10=0.02 avg60=0.41 avg300=0.18 total=1374103\n"
	avg, ok := parsePressure(s)
	if !ok || avg != 0.02 {
		t.Fatalf("avg10 = %v, ok = %v", avg, ok)
	}
	if _, ok := parsePressure(""); ok {
		t.Fatal("empty input should not report pressure")
	}
}

func TestParseNetDev(t *testing.T) {
	s := `Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:  1000 10 0 0 0 0 0 0 1000 10 0 0 0 0 0 0
 wlan0: 421401532 100 0 0 0 0 0 0 914564168 200 0 0 0 0 0 0
`
	got := parseNetDev(s)
	if len(got) != 2 {
		t.Fatalf("got %d interfaces, want 2", len(got))
	}
	if got["wlan0"].rx != 421401532 || got["wlan0"].tx != 914564168 {
		t.Errorf("wlan0 = %+v", got["wlan0"])
	}
}

func TestParseDefaultRoute(t *testing.T) {
	s := `Iface	Destination	Gateway 	Flags	RefCnt	Use	Metric	Mask		MTU	Window	IRTT
wlan0	00000000	0102A8C0	0003	0	0	600	00000000	0	0	0
wlan0	0002A8C0	00000000	0001	0	0	600	00FFFFFF	0	0	0
`
	if got := parseDefaultRoute(s); got != "wlan0" {
		t.Errorf("default route = %q, want wlan0", got)
	}
}

func TestParseDiskstats(t *testing.T) {
	s := `   8       0 sda 100 0 2048 0 0 0 0 0 0 0 0
   8       1 sda1 100 0 1024 0 0 0 0 0 0 0 0
 259       0 nvme0n1 50 0 4096 0 20 0 5000 0 0 0 0
   7       0 loop0 1 0 8 0 0 0 0 0 0 0 0
`
	read, write := parseDiskstats(s)
	if read != (2048+4096)*512 {
		t.Errorf("read bytes = %d", read)
	}
	if write != 5000*512 {
		t.Errorf("write bytes = %d", write)
	}
}

func TestParseProcStat(t *testing.T) {
	s := `4242 (my (weird) name) S 1 4242 4242 0 -1 4194560 1234 0 0 0 100 50 0 0 20 0 3 0 12345 1000000 250 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0`
	st, err := parseProcStat(s)
	if err != nil {
		t.Fatal(err)
	}
	if st.pid != 4242 || st.ppid != 1 {
		t.Errorf("pid/ppid = %d/%d", st.pid, st.ppid)
	}
	if st.comm != "my (weird) name" {
		t.Errorf("comm = %q", st.comm)
	}
	if st.ticks != 150 {
		t.Errorf("ticks = %d, want 150", st.ticks)
	}
	if st.rssPages != 250 {
		t.Errorf("rss pages = %d, want 250", st.rssPages)
	}
}

func TestParseProcStatRejectsGarbage(t *testing.T) {
	if _, err := parseProcStat("not a stat line"); err == nil {
		t.Fatal("expected an error")
	}
}

func TestClassifyCores(t *testing.T) {
	hybrid := classifyCores([]uint64{5157895, 5157895, 5157895, 5157895, 3500000, 3500000, 3500000, 3500000})
	wantP, wantE := 0, 0
	for _, k := range hybrid {
		switch k {
		case "P":
			wantP++
		case "E":
			wantE++
		}
	}
	if wantP != 4 || wantE != 4 {
		t.Errorf("hybrid classification = %v", hybrid)
	}

	uniform := classifyCores([]uint64{4000000, 4000000, 4000000, 4000000})
	for _, k := range uniform {
		if k != "" {
			t.Errorf("uniform CPU should not be split: %v", uniform)
			break
		}
	}
}

func TestSplitExec(t *testing.T) {
	base, appID := splitExec(`/usr/lib/firefox/firefox %u`)
	if base != "firefox" || appID != "" {
		t.Errorf("firefox: base=%q appID=%q", base, appID)
	}
	base, appID = splitExec(`env BAMF_DESKTOP_FILE_HINT=/x flatpak run org.gnome.Calculator`)
	if base != "flatpak" || appID != "org.gnome.Calculator" {
		t.Errorf("flatpak: base=%q appID=%q", base, appID)
	}
}

func TestSnapshotJSONOmitsUnavailable(t *testing.T) {
	snap := Snapshot{CPU: CPU{Cores: []Core{{Index: 0, Usage: 12}}}}
	data, err := json.Marshal(snap)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if _, ok := decoded["gpu"]; ok {
		t.Error("absent GPU should be omitted")
	}
	cpu, ok := decoded["cpu"].(map[string]any)
	if !ok || cpu["usage"] == nil {
		t.Fatalf("unexpected cpu payload: %v", decoded["cpu"])
	}
	core := cpu["cores"].([]any)[0].(map[string]any)
	if _, ok := core["freq"]; ok {
		t.Error("unknown frequency should be omitted")
	}
}

func TestParseLoadAvg(t *testing.T) {
	load, ok := parseLoadAvg("1.51 2.57 2.00 1/1828 81296\n")
	if !ok || load != 1.51 {
		t.Fatalf("load = %v ok = %v", load, ok)
	}
	if _, ok := parseLoadAvg(""); ok {
		t.Fatal("empty input should not report load")
	}
}

func TestParseUptime(t *testing.T) {
	uptime, ok := parseUptime("7518.74 118220.98\n")
	if !ok || uptime != 7518 {
		t.Fatalf("uptime = %v ok = %v", uptime, ok)
	}
	if _, ok := parseUptime("not-a-number 1\n"); ok {
		t.Fatal("garbage input should not report uptime")
	}
}
