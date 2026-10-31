package daemon

import (
	"github.com/aldehir/slime/internal/rpc"
)

// A floating tab is an ordinary tab shown over another (its host)
// rather than in a slot of its own: t.float says which, and where. It
// stays in ws.tabs, so ids, the CLI, and tab.close treat it as any tab.
// Floats are one level deep: a host is never floating itself, and when
// a host goes its floats dock, or move onto the host it floats over.

// hostOf is the tab a window shows for t: t's host if it floats, else t.
func (t *tab) hostOf() *tab {
	if t.float != nil {
		if h := t.ws.tabByID(t.float.Over); h != nil {
			return h
		}
	}
	return t
}

func (ws *workspace) tabByID(id TabID) *tab {
	for _, t := range ws.tabs {
		if t.id == id {
			return t
		}
	}
	return nil
}

// floatsOf lists the tabs floating over host.
func (ws *workspace) floatsOf(host *tab) []*tab {
	var out []*tab
	for _, t := range ws.tabs {
		if t.float != nil && t.float.Over == host.id {
			out = append(out, t)
		}
	}
	return out
}

// areaOf is the part of tab area a that t's panes share: all of it for
// an ordinary tab, its rect's for a float. The window takes its header
// off as well; the estimate leaves that to it.
func (t *tab) areaOf(a Area) Area {
	if t.float == nil {
		return a
	}
	r := t.float.Rect
	a.Width = uint32(uint64(a.Width) * uint64(r.W) / Whole)
	a.Height = uint32(uint64(a.Height) * uint64(r.H) / Whole)
	return a
}

// raiseLocked puts a float on top of its host's others.
func (ws *workspace) raiseLocked(t *tab) {
	ws.nextZ++
	t.float.Z = ws.nextZ
}

// floatLocked makes t float over host, or moves it there from another
// host, with its own floats moving onto host too. It reports whether
// anything changed.
func (s *Server) floatLocked(t, host *tab, rect rpc.FloatRect) bool {
	ws := t.ws
	if t.float != nil && t.float.Over == host.id {
		return false
	}
	for _, f := range ws.floatsOf(t) {
		f.float.Over = host.id
		s.emitLocked(rpc.EvTabFloated, rpc.TabFloatedParams{ID: f.id, Over: host.id}, nil, nil)
	}
	if t.float == nil {
		t.float = &rpc.Float{Rect: rect}
		ws.raiseLocked(t)
	}
	t.float.Over = host.id
	s.log.Info("tab floated", "tab", t.id, "over", host.id)
	s.emitLocked(rpc.EvTabFloated, rpc.TabFloatedParams{ID: t.id, Over: host.id}, nil, nil)
	return true
}

// dockLocked makes a floating tab ordinary, placing it in ws.tabs
// right after tab after.
func (s *Server) dockLocked(t, after *tab) {
	ws := t.ws
	t.float = nil
	for i, x := range ws.tabs {
		if x == t {
			ws.tabs = append(ws.tabs[:i], ws.tabs[i+1:]...)
			break
		}
	}
	at := len(ws.tabs)
	for i, x := range ws.tabs {
		if x == after {
			at = i + 1
			break
		}
	}
	ws.tabs = append(ws.tabs[:at], append([]*tab{t}, ws.tabs[at:]...)...)
	s.log.Info("tab docked", "tab", t.id)
	s.emitLocked(rpc.EvTabDocked, rpc.TabEventParams{ID: t.id}, nil, nil)
}

// dockFloatsLocked docks the floats of a host that's going, right after
// it in their order, so they take its place once it's removed.
func (s *Server) dockFloatsLocked(host *tab) {
	after := host
	for _, f := range host.ws.floatsOf(host) {
		s.dockLocked(f, after)
		after = f
	}
}

// tabFloat floats a tab over another, or changes its rect, whether it's
// minimized, or raises it.
func (s *Server) tabFloat(_ *callCtx, p rpc.TabFloatParams) (rpc.Empty, error) {
	if p.Rect != nil {
		if err := p.Rect.Validate(); err != nil {
			return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "%v", err)
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tabs[p.ID]
	if t == nil {
		return rpc.Empty{}, errNoTab
	}
	ws := t.ws
	var host *tab
	switch {
	case !p.Over.IsZero():
		if host = s.tabs[p.Over]; host == nil {
			return rpc.Empty{}, errNoTab
		}
		if host.ws != ws {
			return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "tab %s is in another workspace", p.Over)
		}
	case t.float == nil:
		if ws.active == nil {
			return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "tab.float needs a tab to float over")
		}
		host = ws.active.hostOf()
	}
	if host != nil {
		if host == t {
			return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "tab %s can't float over itself", t.id)
		}
		if host.float != nil {
			return rpc.Empty{}, rpc.Errorf(rpc.CodeInvalidParams, "tab %s is floating", host.id)
		}
	}
	rect := rpc.DefaultFloat
	if p.Rect != nil {
		rect = *p.Rect
	}
	changed := false
	if host != nil {
		changed = s.floatLocked(t, host, rect)
	}
	if p.Rect != nil && t.float.Rect != *p.Rect {
		t.float.Rect = *p.Rect
		changed = true
	}
	if p.Minimized != nil && t.float.Minimized != *p.Minimized {
		t.float.Minimized = *p.Minimized
		changed = true
		// A minimized float has nothing to type into: the input goes to
		// its host.
		if t.float.Minimized && ws.active == t {
			s.selectTabLocked(ws, t.hostOf())
		}
	}
	if p.Raise && t.float.Z != ws.nextZ {
		ws.raiseLocked(t)
		changed = true
	}
	if changed {
		s.retileLocked(t)
		s.changedLocked(ws, nil)
	}
	return rpc.Empty{}, nil
}

// tabDock makes a floating tab ordinary again, right after its host.
func (s *Server) tabDock(_ *callCtx, p rpc.TabParams) (rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tabs[p.ID]
	if t == nil {
		return rpc.Empty{}, errNoTab
	}
	if t.float == nil {
		return rpc.Empty{}, nil
	}
	s.dockLocked(t, t.hostOf())
	s.retileLocked(t)
	s.changedLocked(t.ws, nil)
	return rpc.Empty{}, nil
}
