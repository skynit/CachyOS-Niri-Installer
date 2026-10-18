package main

// Snapshot is one line of the helper's newline-delimited JSON stream.
// Optional measurements are pointers so the UI can render "unavailable"
// instead of a misleading zero.
type Snapshot struct {
	TS        int64   `json:"ts"`
	Interval  int     `json:"intervalMs"`
	Load1     float64 `json:"load1,omitempty"`
	UptimeSec int64   `json:"uptimeSec,omitempty"`
	CPU       CPU     `json:"cpu"`
	Mem       Mem     `json:"mem"`
	Net       Net     `json:"net"`
	Disk      Rate    `json:"disk"`
	GPU       *GPU    `json:"gpu,omitempty"`
	Power     *Power  `json:"power,omitempty"`
	Battery   *Batt   `json:"battery,omitempty"`
	Procs     []Proc  `json:"procs"`
}

type CPU struct {
	Name  string   `json:"name,omitempty"`
	Usage float64  `json:"usage"`
	Temp  *float64 `json:"temp,omitempty"`
	Cores []Core   `json:"cores"`
}

type Core struct {
	Index int      `json:"i"`
	Usage float64  `json:"use"`
	Freq  *float64 `json:"freq,omitempty"`
	Max   float64  `json:"max,omitempty"`
	Kind  string   `json:"kind,omitempty"`
}

type Mem struct {
	TotalKB       int64   `json:"total"`
	UsedKB        int64   `json:"used"`
	AvailableKB   int64   `json:"available"`
	CachedKB      int64   `json:"cached"`
	SwapTotalKB   int64   `json:"swapTotal"`
	SwapUsedKB    int64   `json:"swapUsed"`
	CompressedKB  int64   `json:"compressed"`
	Pressure      string  `json:"pressure,omitempty"`
	PressureAvg10 float64 `json:"pressureAvg10"`
}

type Net struct {
	Iface   string  `json:"iface,omitempty"`
	Rx      float64 `json:"rx"`
	Tx      float64 `json:"tx"`
	RxTotal uint64  `json:"rxTotal"`
	TxTotal uint64  `json:"txTotal"`
}

type Rate struct {
	Read  float64 `json:"read"`
	Write float64 `json:"write"`
}

type GPU struct {
	Name       string   `json:"name,omitempty"`
	Vendor     string   `json:"vendor,omitempty"`
	Usage      *float64 `json:"usage,omitempty"`
	Freq       *float64 `json:"freq,omitempty"`
	Temp       *float64 `json:"temp,omitempty"`
	Power      *float64 `json:"power,omitempty"`
	MemUsedKB  *int64   `json:"memUsed,omitempty"`
	MemTotalKB *int64   `json:"memTotal,omitempty"`
}

type Power struct {
	Pkg *float64 `json:"pkg,omitempty"`
}

type Batt struct {
	Percent *float64 `json:"percent,omitempty"`
	Status  string   `json:"status,omitempty"`
	Power   *float64 `json:"power,omitempty"`
}

// Proc is one application row: helper processes are folded into the app
// they belong to, so Count > 1 means several processes were merged.
type Proc struct {
	Name  string  `json:"name"`
	Icon  string  `json:"icon,omitempty"`
	CPU   float64 `json:"cpu"`
	MemKB int64   `json:"memKB"`
	Count int     `json:"count"`
}
