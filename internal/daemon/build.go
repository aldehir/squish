package daemon

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/aldehir/slime/internal/rpc"
)

// CurrentBuild identifies this executable (rpc.Build): the name of the
// build directory it sits in (bin/<id>/slime, as slime-gui copies it
// and hosts install it), else "<size>-<mtime>" in hex as slime-gui
// names its copies; and its mtime, which orders takeovers.
var CurrentBuild = sync.OnceValue(func() rpc.Build {
	exe, err := os.Executable()
	if err != nil {
		return rpc.Build{ID: "unknown"}
	}
	return buildOf(exe)
})

func buildOf(exe string) rpc.Build {
	fi, err := os.Stat(exe)
	if err != nil {
		return rpc.Build{ID: "unknown"}
	}
	b := rpc.Build{Time: fi.ModTime().Unix()}
	dir := filepath.Dir(exe)
	if filepath.Base(filepath.Dir(dir)) == "bin" {
		b.ID = filepath.Base(dir)
	} else {
		b.ID = fmt.Sprintf("%x-%x", fi.Size(), fi.ModTime().UnixNano())
	}
	return b
}

// daemonInfo describes the daemon: its process, build, state directory,
// and arguments.
func (s *Server) daemonInfo(_ *callCtx, _ rpc.Empty) (*rpc.DaemonInfoResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return &rpc.DaemonInfoResult{PID: uint32(os.Getpid()), Build: s.build, Started: s.started.UnixMilli(), StateDir: s.stateDir, Args: s.args}, nil
}

// Newer says whether build b is newer than a: later by Time, or by ID
// when the times tie (a copy keeps its mtime).
func Newer(b, a rpc.Build) bool {
	return b.Time > a.Time
}
