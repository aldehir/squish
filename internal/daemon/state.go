package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/aldehir/squish/internal/rpc"
)

// The model on disk: model.json in the state directory describes the
// daemon's structure (workspaces, tabs, trees, focus, what each pane
// runs and where), rewritten, debounced, on every change while the
// daemon runs, and kept when the daemon stops to be replaced (daemon.stop
// with save). A daemon starting with a model.json restores it: the same
// ids, the same layout, and every terminal pane relaunched with its
// command in the directory its shell last reported, as tmux-resurrect
// does. The programs that ran in them don't come back; the first line of
// each restored pane says so.

// Model is model.json.
type Model struct {
	Version    int              `json:"version"`
	Build      rpc.Build        `json:"build"`
	Written    int64            `json:"written"` // unix ms
	Instance   string           `json:"instance,omitempty"`
	NextWS     uint32           `json:"next_workspace"`
	Workspaces []ModelWorkspace `json:"workspaces"`
	// Moved forwards an old pane id ("w.t.p") to its current one.
	Moved map[string]string `json:"moved,omitempty"`
	Hosts []ModelHost       `json:"hosts,omitempty"`
}

const modelVersion = 1

type ModelWorkspace struct {
	ID         uint32     `json:"id"`
	NextTab    uint32     `json:"next_tab"`
	NextZ      uint32     `json:"next_z,omitempty"`
	Name       string     `json:"name"`
	Active     rpc.TabID  `json:"active,omitzero"`
	Area       Area       `json:"area,omitzero"`
	Grid       Size       `json:"grid,omitzero"`
	DetachedAt int64      `json:"detached_at,omitempty"`
	Tabs       []ModelTab `json:"tabs"`
}

type ModelTab struct {
	ID       rpc.TabID   `json:"id"`
	NextPane uint32      `json:"next_pane"`
	Name     string      `json:"name,omitempty"`
	Tree     *rpc.Node   `json:"tree"`
	Focus    rpc.PaneID  `json:"focus,omitzero"`
	Zoom     rpc.PaneID  `json:"zoom,omitzero"`
	Float    *rpc.Float  `json:"float,omitempty"`
	Panes    []ModelPane `json:"panes"`
}

// ModelPane is what relaunches a pane: a terminal's command as it was
// asked for ("" for the shell), its environment, and the directory its
// shell last reported (none if it never did, or it's another host's);
// a browser's url and title.
type ModelPane struct {
	ID      rpc.PaneID        `json:"id"`
	Kind    rpc.PaneKind      `json:"kind,omitempty"`
	Command string            `json:"command,omitempty"`
	Cwd     string            `json:"cwd,omitempty"`
	Env     map[string]string `json:"env,omitempty"`
	Created int64             `json:"created"`
	Size    Size              `json:"size,omitzero"`
	URL     string            `json:"url,omitempty"`
	Title   string            `json:"title,omitempty"`
}

// ModelHost keeps a host's id and destination, so a window's grouping
// and a browser's proxy port survive; the connection itself doesn't.
type ModelHost struct {
	ID   uint32 `json:"id"`
	Dest string `json:"dest"`
	Port int    `json:"port,omitempty"`
}

// modelDebounce is how long after a change the model is written.
const modelDebounce = 100 * time.Millisecond

// modelWriter schedules writes of model.json.
type modelWriter struct {
	mu    sync.Mutex
	timer *time.Timer
	// write serializes the file writes.
	write sync.Mutex
}

// modelEvent says whether an event changes what model.json keeps.
func modelEvent(name string) bool {
	switch name {
	case rpc.EvPaneTitle, rpc.EvPaneBell, rpc.EvPaneStatus, rpc.EvHostPrompt, rpc.EvClientAction,
		rpc.EvScriptOutput, rpc.EvScriptDone, rpc.EvConfigChanged, rpc.EvPaneAttached,
		rpc.EvWorkspaceViewerJoined, rpc.EvWorkspaceViewerLeft:
		return false
	}
	return true
}

// markDirty has model.json written soon. Takes no lock of the server's.
func (s *Server) markDirty() {
	if s.stateDir == "" {
		return
	}
	s.model.mu.Lock()
	defer s.model.mu.Unlock()
	if s.model.timer == nil {
		s.model.timer = time.AfterFunc(modelDebounce, s.flushModel)
	}
}

// flushModel writes the model as it is now.
func (s *Server) flushModel() {
	s.model.mu.Lock()
	s.model.timer = nil
	s.model.mu.Unlock()
	s.mu.Lock()
	if s.stopped {
		// daemonStop wrote the last one, or state is being cleared.
		s.mu.Unlock()
		return
	}
	m := s.modelLocked()
	s.mu.Unlock()
	if err := s.writeModel(m); err != nil {
		s.log.Error("writing model", "err", err)
	}
}

// modelLocked is the structure as model.json keeps it.
func (s *Server) modelLocked() *Model {
	m := &Model{
		Version:    modelVersion,
		Build:      s.build,
		Written:    time.Now().UnixMilli(),
		Instance:   os.Getenv("SQUISH_INSTANCE"),
		NextWS:     s.nextWS,
		Workspaces: []ModelWorkspace{},
		Hosts:      s.hostsModelLocked(),
	}
	ids := make([]uint32, 0, len(s.workspaces))
	for id := range s.workspaces {
		ids = append(ids, id)
	}
	for i := 1; i < len(ids); i++ {
		for j := i; j > 0 && ids[j] < ids[j-1]; j-- {
			ids[j], ids[j-1] = ids[j-1], ids[j]
		}
	}
	for _, id := range ids {
		ws := s.workspaces[id]
		if ws.killed {
			continue
		}
		mw := ModelWorkspace{ID: ws.id, NextTab: ws.nextTab, NextZ: ws.nextZ, Name: ws.name, Active: ws.activeID(), Area: ws.area, Grid: ws.grid, Tabs: []ModelTab{}}
		if !ws.detachedAt.IsZero() {
			mw.DetachedAt = ws.detachedAt.UnixMilli()
		}
		for _, t := range ws.tabs {
			mt := ModelTab{ID: t.id, NextPane: t.nextPane, Name: t.name, Tree: t.root.Clone(), Focus: t.focus, Zoom: t.zoom, Panes: []ModelPane{}}
			if t.float != nil {
				f := *t.float
				mt.Float = &f
			}
			for _, id := range t.root.Panes() {
				if p := s.panes[id]; p != nil {
					mt.Panes = append(mt.Panes, p.model())
				}
			}
			mw.Tabs = append(mw.Tabs, mt)
		}
		m.Workspaces = append(m.Workspaces, mw)
	}
	for from, to := range s.moved {
		if m.Moved == nil {
			m.Moved = map[string]string{}
		}
		m.Moved[from.String()] = to.String()
	}
	return m
}

// model describes the pane for model.json: what would start it again.
func (p *Pane) model() ModelPane {
	p.mu.Lock()
	defer p.mu.Unlock()
	m := ModelPane{ID: p.id, Command: p.asked, Env: p.env, Created: p.created.UnixMilli(), Size: p.size}
	if !p.done {
		pwd, _ := p.term.Pwd()
		m.Cwd = pwdPath(pwd, localHost())
	}
	return m
}

func (b *BrowserPane) model() ModelPane {
	b.mu.Lock()
	defer b.mu.Unlock()
	return ModelPane{ID: b.id, Kind: rpc.PaneBrowser, Created: b.created.UnixMilli(), URL: b.url, Title: b.title}
}

// writeModel writes m as model.json, whole: to a temp file, then over
// the old.
func (s *Server) writeModel(m *Model) error {
	s.model.write.Lock()
	defer s.model.write.Unlock()
	if err := os.MkdirAll(s.stateDir, 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(m, "", " ")
	if err != nil {
		return err
	}
	path := filepath.Join(s.stateDir, "model.json")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// readModel reads the state directory's model.json; nil if there is
// none.
func readModel(dir string) (*Model, error) {
	b, err := os.ReadFile(filepath.Join(dir, "model.json"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var m Model
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("model.json: %w", err)
	}
	if m.Version != modelVersion {
		return nil, fmt.Errorf("model.json: version %d, not %d", m.Version, modelVersion)
	}
	return &m, nil
}

// clearState removes model.json: the daemon exits with nothing to
// restore (idle, or stopped for good).
func (s *Server) clearState() {
	if s.stateDir == "" {
		return
	}
	s.model.mu.Lock()
	if s.model.timer != nil {
		s.model.timer.Stop()
		s.model.timer = nil
	}
	s.model.mu.Unlock()
	s.model.write.Lock()
	defer s.model.write.Unlock()
	os.Remove(filepath.Join(s.stateDir, "model.json"))
	os.Remove(filepath.Join(s.stateDir, "model.json.tmp"))
}

// restoreBanner is the first line of a restored pane: its program is a
// new one, however familiar the prompt.
const restoreBanner = "\x1b[0m[squish restarted; this pane was relaunched]\r\n"

// restore rebuilds the structure in m with the same ids and relaunches
// every pane: a terminal's command in the directory its shell last
// reported (home, if that's gone), a browser at its url. A pane that
// can't start goes, and its tree closes over it. Before clients are
// served.
func (s *Server) restore(m *Model) {
	type pending struct {
		t  *tab
		mp ModelPane
	}
	var pend []pending
	s.mu.Lock()
	s.nextWS = max(s.nextWS, m.NextWS)
	for _, mw := range m.Workspaces {
		ws := &workspace{id: mw.ID, name: mw.Name, nextTab: mw.NextTab, nextZ: mw.NextZ, viewers: map[*conn]*viewer{}, area: mw.Area, grid: mw.Grid, detachedAt: time.Now()}
		if mw.DetachedAt != 0 {
			ws.detachedAt = time.UnixMilli(mw.DetachedAt)
		}
		s.workspaces[ws.id] = ws
		for _, mt := range mw.Tabs {
			if mt.Tree == nil {
				continue
			}
			t := &tab{id: mt.ID, ws: ws, name: mt.Name, root: mt.Tree, nextPane: mt.NextPane, focus: mt.Focus, zoom: mt.Zoom}
			if mt.Float != nil {
				f := *mt.Float
				t.float = &f
			}
			s.tabs[t.id] = t
			ws.tabs = append(ws.tabs, t)
			if mw.Active == t.id {
				ws.active = t
			}
			for _, mp := range mt.Panes {
				pend = append(pend, pending{t, mp})
			}
		}
	}
	for from, to := range m.Moved {
		f, err1 := rpc.ParsePaneID(from)
		t, err2 := rpc.ParsePaneID(to)
		if err1 == nil && err2 == nil {
			s.moved[f] = t
		}
	}
	s.restoreHostsLocked(m.Hosts)
	s.mu.Unlock()
	s.log.Info("restoring", "workspaces", len(m.Workspaces), "panes", len(pend), "from", m.Build.ID)

	type restored struct {
		t  *tab
		st *started
	}
	var ok []restored
	var gone []pending
	for _, pd := range pend {
		st, err := s.relaunch(pd.mp)
		if err != nil {
			s.log.Warn("pane not restored", "pane", pd.mp.ID, "command", pd.mp.Command, "err", err)
			gone = append(gone, pd)
			continue
		}
		ok = append(ok, restored{pd.t, st})
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range ok {
		p := s.addPaneLocked(r.t, r.st)
		if pn, ok := p.(*Pane); ok {
			s.log.Info("pane restored", "pane", pn.id, "command", r.st.command, "pid", r.st.pty.PID())
		}
	}
	for _, g := range gone {
		t := g.t
		if s.tabs[t.id] != t {
			continue
		}
		s.takePaneLocked(t, g.mp.ID)
		if t.root == nil {
			s.removeTabLocked(t)
		}
	}
	for from, to := range s.moved {
		if s.panes[to] == nil {
			delete(s.moved, from)
		}
	}
	// A workspace left empty (every pane lost) goes, as it does when its
	// last tab closes with no viewer.
	for _, ws := range s.workspaces {
		if len(ws.tabs) == 0 {
			s.removeWorkspaceLocked(ws)
		}
	}
	s.checkIdleLocked()
	s.log.Info("restored", "panes", len(ok), "lost", len(gone))
	s.markDirty()
}

// relaunch starts what a model's pane ran, outside the lock, with the
// banner as its terminal's first line. A browser needs nothing started.
func (s *Server) relaunch(mp ModelPane) (*started, error) {
	spec := &rpc.PaneSpec{Kind: mp.Kind, URL: mp.URL, Command: mp.Command, Env: mp.Env}
	if mp.Kind == rpc.PaneTerminal {
		// A shell can be in a directory that's gone: start it at home.
		if fi, err := os.Stat(mp.Cwd); mp.Cwd != "" && err == nil && fi.IsDir() {
			spec.Cwd = mp.Cwd
		}
	}
	size := mp.Size
	if size.Cols == 0 || size.Rows == 0 {
		size.Cols, size.Rows = defaultSize.Cols, defaultSize.Rows
	}
	st, err := s.startPane(mp.ID, spec, size)
	if err != nil {
		return nil, err
	}
	if st.term != nil {
		st.term.Write([]byte(restoreBanner))
	}
	st.title = mp.Title
	if mp.Created != 0 {
		st.created = time.UnixMilli(mp.Created)
	}
	return st, nil
}
