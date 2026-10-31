package daemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aldehir/slime/internal/pty"
	"github.com/aldehir/slime/internal/rpc"
)

// newStateHarness is a harness whose server keeps its model in dir.
func newStateHarness(t *testing.T, dir string) *harness {
	h := &harness{t: t}
	srv, err := NewServer(runtime(t), Options{StateDir: dir, Spawn: func(o pty.Options) (pty.Pty, error) {
		p := newFakePty(o)
		h.mu.Lock()
		h.ptys = append(h.ptys, p)
		h.opts = append(h.opts, o)
		h.mu.Unlock()
		return p, nil
	}})
	if err != nil {
		t.Fatal(err)
	}
	h.srv = srv
	t.Cleanup(srv.Close)
	return h
}

// restoreFrom does what Serve does with a state directory.
func (h *harness) restoreFrom(dir string) {
	h.t.Helper()
	m, err := readModel(dir)
	if err != nil {
		h.t.Fatal(err)
	}
	if m == nil {
		h.t.Fatal("no model.json")
	}
	h.srv.restore(m)
}

// waitModel waits for model.json to say what want checks.
func waitModel(t *testing.T, dir string, want func(*Model) bool) *Model {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		m, err := readModel(dir)
		if err == nil && m != nil && want(m) {
			return m
		}
		if time.Now().After(deadline) {
			t.Fatalf("model.json never matched; last %+v (%v)", m, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestModelWrittenAndRestored(t *testing.T) {
	dir := t.TempDir()
	h := newStateHarness(t, dir)
	w := h.window()
	pane := w.newWorkspace()
	// A split running a command, a browser, and a pane moved into a
	// float; the first pane reports a directory.
	a, created := w.split(pane, Right, 3000, "go test ./...")
	w.absorb(a)
	var bc rpc.Created
	a, err := w.call(rpc.PaneSplit, rpc.PaneSplitParams{Pane: pane, Direction: Down, Kind: rpc.PaneBrowser, URL: "http://example/"}, &bc)
	if err != nil {
		t.Fatal(err)
	}
	w.absorb(a)
	var moved rpc.Created
	a, err = w.call(rpc.PaneMove, rpc.PaneMoveParams{Pane: created.Pane, Float: &rpc.FloatTarget{}}, &moved)
	if err != nil {
		t.Fatal(err)
	}
	w.absorb(a)
	cwd := t.TempDir()
	h.pty(0).emit("\x1b]7;file://localhost/" + filepath.ToSlash(cwd) + "\x1b\\")
	m := waitModel(t, dir, func(m *Model) bool {
		if len(m.Workspaces) != 1 || len(m.Workspaces[0].Tabs) != 2 || len(m.Moved) != 1 {
			return false
		}
		for _, p := range m.Workspaces[0].Tabs[0].Panes {
			if p.ID == pane && p.Cwd != "" {
				return true
			}
		}
		return false
	})
	if _, err := os.Stat(filepath.Join(dir, "model.json.tmp")); err == nil {
		t.Error("model.json.tmp left behind")
	}
	var commands []string
	for _, tb := range m.Workspaces[0].Tabs {
		for _, p := range tb.Panes {
			commands = append(commands, p.Command)
			if p.ID == pane && filepath.Clean(p.Cwd) != filepath.Clean(cwd) {
				t.Errorf("cwd %q, want %q", p.Cwd, cwd)
			}
			if p.Kind == rpc.PaneBrowser && p.URL != "http://example/" {
				t.Errorf("browser %+v", p)
			}
		}
	}
	if got := strings.Join(commands, ","); got != ",,go test ./..." {
		t.Errorf("commands %q", got)
	}

	// The daemon stops to be replaced: the model stays, and the window
	// hears daemon.restarting.
	c := h.connect()
	build := rpc.Build{ID: "next", Time: h.srv.build.Time + 1}
	if err := c.Call(rpc.DaemonStop, rpc.DaemonStopParams{Save: true, Build: build}, nil); err != nil {
		t.Fatal(err)
	}
	// Read without drawing: frames of panes whose earlier frames a call
	// set aside can't apply to this window's screens.
	deadline := time.Now().Add(5 * time.Second)
	for {
		_, msg, err := w.c.Recv()
		if err != nil || time.Now().After(deadline) {
			t.Fatalf("no daemon.restarting: %v", err)
		}
		if name, params, ok := Notification(msg); ok && name == rpc.EvDaemonRestarting {
			var p rpc.DaemonRestartingParams
			json.Unmarshal(params, &p)
			if p.Build != build {
				t.Errorf("restarting %+v", p)
			}
			break
		}
	}
	select {
	case <-h.srv.stopC:
	case <-time.After(5 * time.Second):
		t.Fatal("stopC never closed")
	}
	if !h.srv.keepState {
		t.Error("state not kept")
	}
	h.srv.Close()
	// Pane exits after the stop don't rewrite the model.
	time.Sleep(3 * modelDebounce)
	m2, err := readModel(dir)
	if err != nil || m2 == nil || len(m2.Workspaces) != 1 || len(m2.Workspaces[0].Tabs) != 2 {
		t.Fatalf("model after stop: %+v, %v", m2, err)
	}

	// The next daemon restores: same ids, each pane relaunched with its
	// command in its directory, the browser at its url, the banner first.
	h2 := newStateHarness(t, dir)
	h2.restoreFrom(dir)
	w2 := h2.window()
	var list rpc.WorkspaceListResult
	if err := w2.c.Call(rpc.WorkspaceList, nil, &list); err != nil {
		t.Fatal(err)
	}
	if len(list.Workspaces) != 1 || list.Workspaces[0].ID != pane.WS || len(list.Workspaces[0].Tabs) != 2 || len(list.Panes) != 3 {
		t.Fatalf("restored list %+v", list)
	}
	ids := map[rpc.PaneID]rpc.PaneDesc{}
	for _, p := range list.Panes {
		ids[p.ID] = p
	}
	if _, ok := ids[pane]; !ok {
		t.Errorf("pane %s not restored", pane)
	}
	if b, ok := ids[bc.Pane]; !ok || b.Kind != rpc.PaneBrowser || b.URL != "http://example/" {
		t.Errorf("browser %s: %+v", bc.Pane, b)
	}
	if _, ok := ids[moved.Pane]; !ok {
		t.Errorf("moved pane %s not restored", moved.Pane)
	}
	var info rpc.PaneDesc
	if err := w2.c.Call(rpc.PaneInfo, rpc.PaneParams{ID: created.Pane}, &info); err != nil || info.ID != moved.Pane {
		t.Errorf("old id %s doesn't forward to %s: %+v, %v", created.Pane, moved.Pane, info, err)
	}
	h2.mu.Lock()
	var relaunched []string
	for _, o := range h2.opts {
		relaunched = append(relaunched, o.Command+"@"+filepath.Clean(o.Dir))
	}
	h2.mu.Unlock()
	if len(relaunched) != 2 || !strings.Contains(strings.Join(relaunched, ","), "@"+filepath.Clean(cwd)) || !strings.Contains(strings.Join(relaunched, ","), "go test ./...@") {
		t.Errorf("relaunched %v", relaunched)
	}
	w2.attach(pane.WS, Area{Width: 400, Height: 100, CellW: 10, CellH: 10})
	w2.until(pane, "slime restarted")

	// A plain stop clears the model.
	if err := w2.c.Call(rpc.DaemonStop, nil, nil); err != nil {
		t.Fatal(err)
	}
	<-h2.srv.stopC
	h2.srv.Close()
	h2.srv.clearState()
	if m, _ := readModel(dir); m != nil {
		t.Error("model kept after a plain stop")
	}
}

func TestRestoreSkipsWhatWontStart(t *testing.T) {
	dir := t.TempDir()
	h := newStateHarness(t, dir)
	w := h.window()
	pane := w.newWorkspace()
	a, created := w.split(pane, Right, 5000, "wont-start")
	w.absorb(a)
	waitModel(t, dir, func(m *Model) bool { return len(m.Workspaces) == 1 && len(m.Workspaces[0].Tabs[0].Panes) == 2 })

	h2 := &harness{t: t}
	srv, err := NewServer(runtime(t), Options{StateDir: dir, Spawn: func(o pty.Options) (pty.Pty, error) {
		if o.Command == "wont-start" {
			return nil, os.ErrNotExist
		}
		return newFakePty(o), nil
	}})
	if err != nil {
		t.Fatal(err)
	}
	h2.srv = srv
	t.Cleanup(srv.Close)
	h2.restoreFrom(dir)
	var list rpc.WorkspaceListResult
	if err := h2.connect().Call(rpc.WorkspaceList, nil, &list); err != nil {
		t.Fatal(err)
	}
	if len(list.Panes) != 1 || list.Panes[0].ID != pane {
		t.Fatalf("restored panes %+v", list.Panes)
	}
	if tree := list.Workspaces[0].Tabs[0].Tree; !tree.IsLeaf() || tree.Pane != pane {
		t.Errorf("tree didn't collapse over %s: %+v", created.Pane, tree)
	}
}
