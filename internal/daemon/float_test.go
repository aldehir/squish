package daemon

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/aldehir/slime/internal/rpc"
)

// checkFloatsLocked checks the invariants of floating tabs: each floats
// over a tab of its workspace that floats over nothing, and is in
// ws.tabs and s.tabs.
func (s *Server) checkFloatsLocked() error {
	for _, ws := range s.workspaces {
		for _, t := range ws.tabs {
			if s.tabs[t.id] != t {
				return fmt.Errorf("tab %s in its workspace but not the server's", t.id)
			}
			if t.float == nil {
				continue
			}
			host := ws.tabByID(t.float.Over)
			switch {
			case host == nil:
				return fmt.Errorf("tab %s floats over %s, not in its workspace", t.id, t.float.Over)
			case host == t:
				return fmt.Errorf("tab %s floats over itself", t.id)
			case host.float != nil:
				return fmt.Errorf("tab %s floats over %s, which floats", t.id, host.id)
			}
			if err := t.float.Rect.Validate(); err != nil {
				return fmt.Errorf("tab %s: %v", t.id, err)
			}
		}
	}
	return nil
}

func checkFloats(t *testing.T, h *harness) {
	t.Helper()
	h.srv.mu.Lock()
	defer h.srv.mu.Unlock()
	if err := h.srv.checkFloatsLocked(); err != nil {
		t.Fatal(err)
	}
}

// tabsOf is the workspace's tabs as workspace.info describes them.
func tabsOf(t *testing.T, w *window) []rpc.Tab {
	t.Helper()
	var d rpc.WorkspaceDesc
	if err := w.c.Call(rpc.WorkspaceInfo, rpc.WorkspaceParams{ID: w.ws.ID}, &d); err != nil {
		t.Fatal(err)
	}
	return d.Tabs
}

func tabIDs(tabs []rpc.Tab) string {
	var ids []string
	for _, t := range tabs {
		ids = append(ids, t.ID.String())
	}
	return strings.Join(ids, " ")
}

// TestFloatPaneMove: pane.move with float takes a pane of a two-pane tab
// into a third tab that floats over its own, under a new id that the old
// one forwards to.
func TestFloatPaneMove(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	w.newTab()
	a, created := w.split(first, Right, 5000, "")
	w.absorb(a)
	second := created.Pane
	src := first.TabID()

	var moved rpc.Created
	a, err := w.call(rpc.PaneMove, rpc.PaneMoveParams{Pane: second, Float: &rpc.FloatTarget{}}, &moved)
	if err != nil {
		t.Fatal(err)
	}
	w.absorb(a)
	checkFloats(t, h)
	tabs := tabsOf(t, w)
	if len(tabs) != 3 {
		t.Fatalf("tabs %s", tabIDs(tabs))
	}
	ft := tabs[1]
	if moved.Pane.TabID() != ft.ID || ft.Float == nil || ft.Float.Over != src || ft.Float.Rect != rpc.DefaultFloat {
		t.Fatalf("moved to %s: %+v", moved.Pane, ft)
	}
	if moved.Pane == second {
		t.Errorf("kept its id across tabs")
	}
	h.srv.mu.Lock()
	found := h.srv.paneLocked(second)
	h.srv.mu.Unlock()
	if found == nil || found.paneID() != moved.Pane {
		t.Errorf("old id finds %v", found)
	}
	if w.ws.ActiveTab != ft.ID {
		t.Errorf("active %s, want the float %s", w.ws.ActiveTab, ft.ID)
	}

	// From the float, a pane floats over the float's host too; over a
	// float, or a lone pane over its own tab, it can't.
	a, created = w.split(moved.Pane, Down, 5000, "")
	w.absorb(a)
	var again rpc.Created
	if err := w.c.Call(rpc.PaneMove, rpc.PaneMoveParams{Pane: created.Pane, Float: &rpc.FloatTarget{}}, &again); err != nil {
		t.Fatal(err)
	}
	collect(w.c)
	checkFloats(t, h)
	for _, tab := range tabsOf(t, w) {
		if tab.ID == again.Pane.TabID() && (tab.Float == nil || tab.Float.Over != src) {
			t.Errorf("floated out of a float: %+v", tab.Float)
		}
	}
	if err := w.c.Call(rpc.PaneMove, rpc.PaneMoveParams{Pane: first, Float: &rpc.FloatTarget{}}, nil); !isInvalid(err, "lone pane") {
		t.Errorf("a lone pane over its own tab: %v", err)
	}
}

// TestPaneMoveAt: pane.move with at puts a pane beside another, in that
// pane's tab (a float's, or back into the host's), under a new id there
// and its own in its own tab; at doesn't go with tab or float, or name
// the pane itself.
func TestPaneMoveAt(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	w.newTab()
	a, created := w.split(first, Right, 5000, "")
	w.absorb(a)
	second := created.Pane
	var moved rpc.Created
	a, err := w.call(rpc.PaneMove, rpc.PaneMoveParams{Pane: second, Float: &rpc.FloatTarget{}}, &moved)
	if err != nil {
		t.Fatal(err)
	}
	w.absorb(a)
	inFloat := moved.Pane

	// From the host into the float, under the float's pane.
	a, err = w.call(rpc.PaneMove, rpc.PaneMoveParams{Pane: first, At: inFloat, Side: Down}, &moved)
	if err != nil {
		t.Fatal(err)
	}
	w.absorb(a)
	checkFloats(t, h)
	// The host, left empty, closed, and its float docked in its place.
	tabs := tabsOf(t, w)
	if len(tabs) != 2 || tabs[0].ID != inFloat.TabID() {
		t.Fatalf("tabs %s: want the docked float first, in the closed host's place", tabIDs(tabs))
	}
	ft := tabs[0]
	if ft.Float != nil {
		t.Errorf("still floating with its host gone: %+v", ft.Float)
	}
	if moved.Pane.TabID() != ft.ID || moved.Pane == first {
		t.Errorf("moved to %s, want a new id in %s", moved.Pane, ft.ID)
	}
	tree := ft.Tree
	if tree.IsLeaf() || tree.Axis != rpc.Column || len(tree.Children) != 2 ||
		tree.Children[0].Node.Pane != inFloat || tree.Children[1].Node.Pane != moved.Pane ||
		tree.Children[0].Share != 5000 {
		t.Errorf("tree %+v, want %s over %s halving it", tree, inFloat, moved.Pane)
	}

	// Within its own tab it keeps its id, and goes to the other side.
	a, err = w.call(rpc.PaneMove, rpc.PaneMoveParams{Pane: moved.Pane, At: inFloat, Side: Left}, &moved)
	if err != nil {
		t.Fatal(err)
	}
	w.absorb(a)
	tree = tabsOf(t, w)[0].Tree
	if tree.IsLeaf() || tree.Axis != rpc.Row || tree.Children[0].Node.Pane != moved.Pane || tree.Children[1].Node.Pane != inFloat {
		t.Errorf("tree %+v, want %s left of %s", tree, moved.Pane, inFloat)
	}

	if err := w.c.Call(rpc.PaneMove, rpc.PaneMoveParams{Pane: moved.Pane, At: moved.Pane}, nil); !isInvalid(err, "beside itself") {
		t.Errorf("beside itself: %v", err)
	}
	if err := w.c.Call(rpc.PaneMove, rpc.PaneMoveParams{Pane: moved.Pane, At: inFloat, Tab: ft.ID}, nil); !isInvalid(err, "at and tab") {
		t.Errorf("at with tab: %v", err)
	}
	if err := w.c.Call(rpc.PaneMove, rpc.PaneMoveParams{Pane: moved.Pane, At: inFloat, Float: &rpc.FloatTarget{}}, nil); !isInvalid(err, "at and float") {
		t.Errorf("at with float: %v", err)
	}
	if err := w.c.Call(rpc.PaneMove, rpc.PaneMoveParams{Pane: moved.Pane, At: rpc.PaneID{WS: 9, Tab: 9, N: 9}}, nil); err == nil {
		t.Errorf("beside no such pane: %v", err)
	}
}

// TestFloatHostClosedDocks: closing a host docks its floats in its
// place, the input going to them.
func TestFloatHostClosedDocks(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	w.newWorkspace()
	w.newTab()
	w.newTab()
	w.newTab()
	tabs := tabsOf(t, w)
	f1, other, host, f2 := tabs[0].ID, tabs[1].ID, tabs[2].ID, tabs[3].ID
	for _, f := range []TabID{f1, f2} {
		if err := w.c.Call(rpc.TabFloat, rpc.TabFloatParams{ID: f, Over: host}, nil); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.c.Call(rpc.WorkspaceFocus, rpc.WorkspaceFocusParams{Tab: host}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := w.call(rpc.TabClose, rpc.TabParams{ID: host}, nil); err != nil {
		t.Fatal(err)
	}
	checkFloats(t, h)
	tabs = tabsOf(t, w)
	if got, want := tabIDs(tabs), fmt.Sprintf("%s %s %s", other, f1, f2); got != want {
		t.Errorf("tabs %s, want %s", got, want)
	}
	for _, tab := range tabs {
		if tab.Float != nil {
			t.Errorf("tab %s still floats over %s", tab.ID, tab.Float.Over)
		}
	}
	var d rpc.WorkspaceDesc
	w.c.Call(rpc.WorkspaceInfo, rpc.WorkspaceParams{ID: w.ws.ID}, &d)
	if d.ActiveTab != f1 {
		t.Errorf("active %s, want %s", d.ActiveTab, f1)
	}
}

// TestFloatOverFloatRehomes: floating a host over another tab moves its
// floats onto that one, and docking puts a float right after its host.
func TestFloatOverFloatRehomes(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	w.newWorkspace()
	w.newTab()
	w.newTab()
	tabs := tabsOf(t, w)
	g, host, f := tabs[0].ID, tabs[1].ID, tabs[2].ID
	if err := w.c.Call(rpc.TabFloat, rpc.TabFloatParams{ID: f, Over: host}, nil); err != nil {
		t.Fatal(err)
	}
	if err := w.c.Call(rpc.TabFloat, rpc.TabFloatParams{ID: host, Over: g}, nil); err != nil {
		t.Fatal(err)
	}
	checkFloats(t, h)
	for _, tab := range tabsOf(t, w) {
		if tab.ID != g && (tab.Float == nil || tab.Float.Over != g) {
			t.Errorf("tab %s floats %+v, want over %s", tab.ID, tab.Float, g)
		}
	}
	if err := w.c.Call(rpc.TabDock, rpc.TabParams{ID: f}, nil); err != nil {
		t.Fatal(err)
	}
	if err := w.c.Call(rpc.TabDock, rpc.TabParams{ID: f}, nil); err != nil {
		t.Errorf("docking a docked tab: %v", err)
	}
	checkFloats(t, h)
	if got, want := tabIDs(tabsOf(t, w)), fmt.Sprintf("%s %s %s", g, f, host); got != want {
		t.Errorf("tabs %s, want %s", got, want)
	}
}

func isInvalid(err error, msg string) bool {
	var rerr *rpc.Error
	return errors.As(err, &rerr) && rerr.Code == rpc.CodeInvalidParams && strings.Contains(rerr.Message, msg)
}

func TestFloatRejects(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	w.newTab()
	tabs := tabsOf(t, w)
	a, b := tabs[0].ID, tabs[1].ID
	if err := w.c.Call(rpc.TabFloat, rpc.TabFloatParams{ID: a, Over: a}, nil); !isInvalid(err, "itself") {
		t.Errorf("over itself: %v", err)
	}
	if err := w.c.Call(rpc.TabFloat, rpc.TabFloatParams{ID: b, Over: a}, nil); err != nil {
		t.Fatal(err)
	}
	if err := w.c.Call(rpc.TabFloat, rpc.TabFloatParams{ID: a, Over: b}, nil); !isInvalid(err, "is floating") {
		t.Errorf("over a float: %v", err)
	}
	for _, r := range []rpc.FloatRect{{W: rpc.MinFloat - 1, H: 5000}, {X: 5000, W: 5001, H: 5000}, {Y: 9000, W: 5000, H: 2000}} {
		if err := w.c.Call(rpc.TabFloat, rpc.TabFloatParams{ID: b, Rect: &r}, nil); !isInvalid(err, "out of range") {
			t.Errorf("rect %+v: %v", r, err)
		}
	}
	err := w.c.Call(rpc.PaneMove, rpc.PaneMoveParams{Pane: first, Tab: b, Float: &rpc.FloatTarget{}}, nil)
	if !isInvalid(err, "float and tab") {
		t.Errorf("float and tab: %v", err)
	}
	err = w.c.Call(rpc.PaneMove, rpc.PaneMoveParams{Pane: first, Float: &rpc.FloatTarget{Over: b}}, nil)
	if !isInvalid(err, "floating tab") {
		t.Errorf("pane over a float: %v", err)
	}
	checkFloats(t, h)
}

// TestFloatFocusRestores: focusing a minimized float restores it and
// puts it on top; minimizing the active float gives the input to its
// host.
func TestFloatFocusRestores(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	w.newWorkspace()
	w.newTab()
	w.newTab()
	tabs := tabsOf(t, w)
	host, f1, f2 := tabs[0].ID, tabs[1].ID, tabs[2].ID
	for _, f := range []TabID{f1, f2} {
		if err := w.c.Call(rpc.TabFloat, rpc.TabFloatParams{ID: f, Over: host}, nil); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.c.Call(rpc.WorkspaceFocus, rpc.WorkspaceFocusParams{Tab: f1}, nil); err != nil {
		t.Fatal(err)
	}
	yes := true
	if err := w.c.Call(rpc.TabFloat, rpc.TabFloatParams{ID: f1, Minimized: &yes}, nil); err != nil {
		t.Fatal(err)
	}
	var d rpc.WorkspaceDesc
	w.c.Call(rpc.WorkspaceInfo, rpc.WorkspaceParams{ID: w.ws.ID}, &d)
	if d.ActiveTab != host || !d.Tabs[1].Float.Minimized {
		t.Errorf("minimized: active %s, float %+v", d.ActiveTab, d.Tabs[1].Float)
	}
	if err := w.c.Call(rpc.WorkspaceFocus, rpc.WorkspaceFocusParams{Tab: f1}, nil); err != nil {
		t.Fatal(err)
	}
	d = rpc.WorkspaceDesc{}
	w.c.Call(rpc.WorkspaceInfo, rpc.WorkspaceParams{ID: w.ws.ID}, &d)
	z1, z2 := d.Tabs[1].Float.Z, d.Tabs[2].Float.Z
	if d.ActiveTab != f1 || d.Tabs[1].Float.Minimized || z1 <= z2 {
		t.Errorf("focused: active %s, float %+v, z %d over %d", d.ActiveTab, d.Tabs[1].Float, z1, z2)
	}
}

// TestRetileFloat: with no viewer, a float's panes are measured in its
// rect's share of the tab area.
func TestRetileFloat(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	w.newWorkspace()
	w.newTab()
	tabs := tabsOf(t, w)
	if err := w.c.Call(rpc.WorkspaceResize, rpc.WorkspaceResizeParams{ID: w.ws.ID, Area: Area{Width: 1000, Height: 800, CellW: 10, CellH: 20}}, nil); err != nil {
		t.Fatal(err)
	}
	if err := w.c.Call(rpc.TabFloat, rpc.TabFloatParams{ID: tabs[1].ID, Over: tabs[0].ID}, nil); err != nil {
		t.Fatal(err)
	}
	w.c.Close()
	// 60% of 1000x800 is 600x480: 60x24 cells.
	eventually(t, "retile", func() bool {
		return h.pty(0).getSize() == [2]uint16{100, 40} && h.pty(1).getSize() == [2]uint16{60, 24}
	})
}
