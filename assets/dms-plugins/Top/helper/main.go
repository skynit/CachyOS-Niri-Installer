package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	intervalMs := flag.Int("interval", 1000, "sampling interval in milliseconds")
	topN := flag.Int("procs", 24, "number of application rows to report")
	sortBy := flag.String("sort", "cpu", "sort application rows by cpu or mem")
	once := flag.Bool("once", false, "print one snapshot and exit")
	kill := flag.Bool("kill", false, "send a signal to pids whose /proc/<pid>/exe matches the first argument")
	force := flag.Bool("force", false, "with -kill, send SIGKILL instead of SIGTERM")
	flag.Parse()

	if *kill {
		runKill(flag.Args(), *force)
		return
	}

	interval := time.Duration(*intervalMs) * time.Millisecond
	if interval < 200*time.Millisecond {
		interval = 200 * time.Millisecond
	}
	if *topN < 0 {
		*topN = 0
	}

	if *sortBy != "mem" {
		*sortBy = "cpu"
	}
	s := newSampler(interval, *topN, *sortBy)
	s.prime()

	out := bufio.NewWriterSize(os.Stdout, 64*1024)
	enc := json.NewEncoder(out)

	if *once {
		time.Sleep(interval)
		if err := enc.Encode(s.sample()); err != nil {
			log.Println("encode:", err)
			return
		}
		if err := out.Flush(); err != nil {
			log.Println("flush:", err)
		}
		return
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-signals:
			return
		case <-ticker.C:
			if err := enc.Encode(s.sample()); err != nil {
				return
			}
			if err := out.Flush(); err != nil {
				return
			}
		}
	}
}
