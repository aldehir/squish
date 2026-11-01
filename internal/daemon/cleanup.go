package daemon

import (
	"os"
	"path/filepath"
)

// cleanBuilds removes the builds beside this one: squish-gui runs the
// daemon from a copy in bin/<build>/squish.exe and a host installs it as
// bin/<build>/squish, one directory per build, and a build in use can't
// be replaced, so they pile up. The daemon's own stays; one another
// daemon still runs from can't be removed on Windows (in use) and is
// harmless to on Unix. Not under SQUISH_INSTANCE, so a test daemon
// leaves the user's builds alone.
func (s *Server) cleanBuilds() {
	if os.Getenv("SQUISH_INSTANCE") != "" {
		return
	}
	exe, err := os.Executable()
	if err != nil {
		return
	}
	own := filepath.Dir(exe)
	bin := filepath.Dir(own)
	if filepath.Base(bin) != "bin" {
		return
	}
	inUse := map[string]bool{filepath.Clean(own): true}
	entries, err := os.ReadDir(bin)
	if err != nil {
		return
	}
	for _, e := range entries {
		dir := filepath.Join(bin, e.Name())
		if !e.IsDir() || inUse[filepath.Clean(dir)] || !isBuildDir(dir) {
			continue
		}
		if err := os.RemoveAll(dir); err != nil {
			// Running, on Windows: the next daemon gets it.
			s.log.Debug("old build kept", "dir", dir, "err", err)
			continue
		}
		s.log.Info("removed an old build", "dir", dir)
	}
}

// isBuildDir says whether dir holds nothing but a squish executable: what
// an install leaves, and all cleanBuilds removes.
func isBuildDir(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) == 0 {
		return false
	}
	for _, e := range entries {
		if e.IsDir() || (e.Name() != "squish" && e.Name() != "squish.exe") {
			return false
		}
	}
	return true
}
