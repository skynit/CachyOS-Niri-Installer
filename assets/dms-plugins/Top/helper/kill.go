package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

// runKill terminates processes only while their current /proc/<pid>/exe still
// matches the executable captured by the sampler. PID reuse between the sample
// and the click therefore cannot hit an unrelated process.
func runKill(args []string, force bool) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "-kill requires an executable path followed by pid(s)")
		os.Exit(2)
	}
	exe := args[0]
	pids := make([]int, 0, len(args)-1)
	for _, raw := range args[1:] {
		pid, err := strconv.Atoi(raw)
		if err != nil || pid <= 0 {
			continue
		}
		pids = append(pids, pid)
	}
	sig := syscall.SIGTERM
	if force {
		sig = syscall.SIGKILL
	}
	killed, skipped := killByExe(exe, pids, sig)
	fmt.Printf("killed=%d skipped=%d\n", killed, skipped)
}

func killByExe(exe string, pids []int, sig syscall.Signal) (int, int) {
	if exe == "" {
		return 0, len(pids)
	}
	killed, skipped := 0, 0
	self := os.Getpid()
	for _, pid := range pids {
		if pid <= 1 || pid == self {
			skipped++
			continue
		}
		target, err := os.Readlink("/proc/" + strconv.Itoa(pid) + "/exe")
		if err != nil || filepath.Base(target) != filepath.Base(exe) {
			skipped++
			continue
		}
		if err := syscall.Kill(pid, sig); err != nil {
			skipped++
			continue
		}
		killed++
	}
	return killed, skipped
}
