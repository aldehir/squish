package daemon

import (
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/aldehir/squish/internal/rpc"
)

const definedWorkspace = `
squish.workspace.define{
  name = "dev",
  tabs = {
    squish.layout.horizontal(0.7,
      squish.layout.pane{ command = "a" },
      squish.layout.pane{}),
    squish.layout.vertical(squish.layout.pane{ command = "b" }, squish.layout.browser{ url = "http://x/" }, squish.layout.pane{ command = "c" }),
  },
}
`

// shape is a tree without its pane ids: axes and shares.
func shape(n *rpc.Node) string {
	if n.IsLeaf() {
		return "pane"
	}
	var parts []string
	for _, c := range n.Children {
		parts = append(parts, fmt.Sprintf("%d:%s", c.Share, shape(c.Node)))
	}
	return fmt.Sprintf("%s(%s)", n.Axis, strings.Join(parts, ","))
}

func TestWorkspaceDefineOpenExport(t *testing.T) {
	h, path := newConfigHarness(t, definedWorkspace)
	c := h.connect()
	var cfg rpc.ConfigDesc
	if err := c.Call(rpc.ConfigGet, nil, &cfg); err != nil {
		t.Fatal(err)
	}
	if len(cfg.Workspaces) != 1 || cfg.Workspaces[0].Name != "dev" || len(cfg.Workspaces[0].Tabs) != 2 {
		t.Fatalf("config workspaces %+v", cfg.Workspaces)
	}
	var ws rpc.Workspace
	if err := c.Call(rpc.WorkspaceOpen, rpc.WorkspaceOpenNamedParams{Name: "dev"}, &ws); err != nil {
		t.Fatal(err)
	}
	if ws.Name != "dev" || len(ws.Tabs) != 2 {
		t.Fatalf("opened %+v", ws)
	}
	if got := shape(ws.Tabs[0].Tree); got != "row(7000:pane,3000:pane)" {
		t.Errorf("tab 1 %s", got)
	}
	if got := shape(ws.Tabs[1].Tree); got != "column(3333:pane,3333:pane,3334:pane)" {
		t.Errorf("tab 2 %s", got)
	}
	// Opening it again finds the one open.
	var again rpc.Workspace
	if err := c.Call(rpc.WorkspaceOpen, rpc.WorkspaceOpenNamedParams{Name: "dev"}, &again); err != nil || again.ID != ws.ID {
		t.Fatalf("second open: %+v, %v", again, err)
	}
	if err := c.Call(rpc.WorkspaceOpen, rpc.WorkspaceOpenNamedParams{Name: "nope"}, nil); err == nil {
		t.Error("an undefined workspace opened")
	}

	var ex rpc.WorkspaceExportResult
	if err := c.Call(rpc.WorkspaceExport, rpc.WorkspaceParams{ID: ws.ID}, &ex); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`name = "dev"`, `squish.layout.horizontal(0.7,`, `command = "a"`, `squish.layout.browser{ url = "http://x/" }`, `command = "c"`} {
		if !strings.Contains(ex.Lua, want) {
			t.Errorf("export lacks %q:\n%s", want, ex.Lua)
		}
	}
	// Evaluated again under another name, it makes the same trees.
	lua := definedWorkspace + strings.Replace(ex.Lua, `name = "dev"`, `name = "dev2"`, 1)
	if err := os.WriteFile(path, []byte(lua), 0o600); err != nil {
		t.Fatal(err)
	}
	var reloaded rpc.ConfigDesc
	if err := c.Call(rpc.ConfigReload, nil, &reloaded); err != nil {
		t.Fatal(err)
	}
	if len(reloaded.Errors) > 0 {
		t.Fatalf("exported lua doesn't evaluate: %v\n%s", reloaded.Errors, ex.Lua)
	}
	var ws2 rpc.Workspace
	if err := c.Call(rpc.WorkspaceOpen, rpc.WorkspaceOpenNamedParams{Name: "dev2"}, &ws2); err != nil {
		t.Fatal(err)
	}
	if len(ws2.Tabs) != len(ws.Tabs) {
		t.Fatalf("reopened tabs %d, want %d", len(ws2.Tabs), len(ws.Tabs))
	}
	for i := range ws.Tabs {
		if a, b := shape(ws.Tabs[i].Tree), shape(ws2.Tabs[i].Tree); a != b {
			t.Errorf("tab %d: %s, reopened %s", i+1, a, b)
		}
	}
	// The commands came through: a, the shell, b, (a browser), c, twice.
	h.mu.Lock()
	var commands []string
	for _, o := range h.opts {
		commands = append(commands, o.Command)
	}
	h.mu.Unlock()
	if got := strings.Join(commands, ","); got != "a,,b,c,a,,b,c" {
		t.Errorf("commands %q", got)
	}
}
