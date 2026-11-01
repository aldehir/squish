package daemon

import (
	"fmt"
	"strings"

	"github.com/aldehir/squish/internal/pty"
	"github.com/aldehir/squish/internal/rpc"
)

// Defined workspaces: init.lua names a workspace and its layout with
// squish.workspace.define; workspace.open makes it on demand (or finds
// the one of that name already open), autostart opens it when the
// daemon starts with nothing to restore, and workspace.export writes a
// live workspace back as such a definition.

// autostartWorkspaces opens the config's autostart definitions, unless
// a restore brought workspaces back (which would double them).
func (s *Server) autostartWorkspaces(restored bool) {
	if restored {
		return
	}
	cfg := s.currentConfig()
	if cfg == nil {
		return
	}
	for _, def := range cfg.Workspaces() {
		if !def.Autostart {
			continue
		}
		if _, err := s.openDefined(&callCtx{s: s}, def); err != nil {
			s.log.Warn("autostart workspace", "name", def.Name, "err", err)
		} else {
			s.log.Info("autostart workspace opened", "name", def.Name)
		}
	}
}

// openDefined makes a workspace from a definition, as workspace.new
// would, for the caller.
func (s *Server) openDefined(cl *callCtx, def rpc.WorkspaceDef) (*rpc.Workspace, error) {
	if len(def.Tabs) == 0 {
		return nil, rpc.Errorf(rpc.CodeInvalidParams, "workspace %q is defined with no tabs", def.Name)
	}
	tabs := make([]*rpc.Layout, len(def.Tabs))
	for i, t := range def.Tabs {
		tabs[i] = cloneLayout(t)
	}
	_, err := s.workspaceNew(cl, rpc.WorkspaceNewParams{Name: def.Name, Tabs: tabs})
	if err != nil {
		return nil, err
	}
	ws, _ := cl.result.(*rpc.Workspace)
	return ws, nil
}

// cloneLayout copies a layout: Validate fills in shares, and the
// config's copy stays as written.
func cloneLayout(l *rpc.Layout) *rpc.Layout {
	if l == nil {
		return nil
	}
	if l.IsLeaf() {
		spec := *l.Pane
		if spec.Env != nil {
			env := make(map[string]string, len(spec.Env))
			for k, v := range spec.Env {
				env[k] = v
			}
			spec.Env = env
		}
		return &rpc.Layout{Pane: &spec}
	}
	out := &rpc.Layout{Axis: l.Axis}
	for _, c := range l.Children {
		out.Children = append(out.Children, rpc.LayoutChild{Share: c.Share, Node: cloneLayout(c.Node)})
	}
	return out
}

// workspaceOpen answers with the workspace named, making it from the
// config's definition if none is open.
func (s *Server) workspaceOpen(cl *callCtx, p rpc.WorkspaceOpenNamedParams) (*rpc.Workspace, error) {
	if p.Name == "" {
		return nil, rpc.Errorf(rpc.CodeInvalidParams, "workspace.open needs a name")
	}
	s.mu.Lock()
	var found *workspace
	for _, ws := range s.workspaces {
		if ws.name == p.Name && !ws.killed && (found == nil || ws.id < found.id) {
			found = ws
		}
	}
	s.mu.Unlock()
	if found != nil {
		if p.Attach && cl.c != nil {
			return s.workspaceAttach(cl, rpc.WorkspaceAttachParams{ID: found.id})
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.workspaces[found.id] != found {
			return nil, errNoWorkspace
		}
		if p.Beside != 0 {
			s.openBesideLocked(found, s.workspaces[p.Beside], cl.c)
		}
		return found.structure(), nil
	}
	cfg := s.currentConfig()
	var def *rpc.WorkspaceDef
	if cfg != nil {
		for _, d := range cfg.Workspaces() {
			if d.Name == p.Name {
				def = &d
				break
			}
		}
	}
	if def == nil {
		return nil, rpc.Errorf(rpc.CodeNotFound, "no workspace %q is open or defined in init.lua", p.Name)
	}
	if p.Attach && cl.c != nil {
		// workspaceNew makes the caller a viewer and replies itself.
		_, err := s.workspaceNew(cl, rpc.WorkspaceNewParams{Name: def.Name, Tabs: cloneTabs(def.Tabs), Attach: p.Beside})
		return nil, err
	}
	made := &callCtx{s: s}
	if _, err := s.workspaceNew(made, rpc.WorkspaceNewParams{Name: def.Name, Tabs: cloneTabs(def.Tabs), Attach: p.Beside}); err != nil {
		return nil, err
	}
	ws, _ := made.result.(*rpc.Workspace)
	return ws, nil
}

func cloneTabs(tabs []*rpc.Layout) []*rpc.Layout {
	out := make([]*rpc.Layout, len(tabs))
	for i, t := range tabs {
		out[i] = cloneLayout(t)
	}
	return out
}

// workspaceExport writes a workspace as a squish.workspace.define call:
// its tabs' trees with their shares, each terminal pane's command (none
// for the shell) and the directory its shell last reported as cwd, and
// browsers as urls. A running program isn't captured: a shell comes
// back as a shell.
func (s *Server) workspaceExport(_ *callCtx, p rpc.WorkspaceParams) (*rpc.WorkspaceExportResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ws := s.workspaces[p.ID]
	if ws == nil {
		return nil, errNoWorkspace
	}
	shell := s.shellCommandLocked()
	var b strings.Builder
	fmt.Fprintf(&b, "squish.workspace.define{\n  name = %s,\n  tabs = {\n", luaQuote(ws.name))
	for _, t := range ws.tabs {
		if t.root == nil {
			continue
		}
		b.WriteString("    ")
		s.exportNode(&b, t.root, shell, 2)
		b.WriteString(",\n")
	}
	b.WriteString("  },\n}\n")
	return &rpc.WorkspaceExportResult{Lua: b.String()}, nil
}

// shellCommandLocked is shellCommand under the lock.
func (s *Server) shellCommandLocked() string {
	if s.config != nil {
		return s.config.Shell()
	}
	return ""
}

// exportNode writes n as squish.layout calls, indented depth levels: a
// two-way split as horizontal/vertical(ratio, a, b), a wider one as
// the raw split table its shares need.
func (s *Server) exportNode(b *strings.Builder, n *Node, shell string, depth int) {
	indent := strings.Repeat("  ", depth)
	if n.IsLeaf() {
		b.WriteString(s.exportLeaf(n.Pane, shell))
		return
	}
	if len(n.Children) == 2 {
		fn := "horizontal"
		if n.Axis == Column {
			fn = "vertical"
		}
		fmt.Fprintf(b, "squish.layout.%s(%s,\n%s  ", fn, trimFloat(float64(n.Children[0].Share)/Whole), indent)
		s.exportNode(b, n.Children[0].Node, shell, depth+1)
		fmt.Fprintf(b, ",\n%s  ", indent)
		s.exportNode(b, n.Children[1].Node, shell, depth+1)
		b.WriteString(")")
		return
	}
	fmt.Fprintf(b, "{ split = { axis = %q, children = {\n", n.Axis.String())
	for _, c := range n.Children {
		fmt.Fprintf(b, "%s  { share = %d, node = ", indent, c.Share)
		s.exportNode(b, c.Node, shell, depth+1)
		b.WriteString(" },\n")
	}
	fmt.Fprintf(b, "%s} } }", indent)
}

// exportLeaf is one pane as squish.layout.pane{...} or browser{...}.
func (s *Server) exportLeaf(id PaneID, shell string) string {
	pn := s.panes[id]
	switch p := pn.(type) {
	case *BrowserPane:
		p.mu.Lock()
		url := p.url
		p.mu.Unlock()
		return fmt.Sprintf("squish.layout.browser{ url = %s }", luaQuote(url))
	case *Pane:
		var fields []string
		p.mu.Lock()
		command := p.command
		var pwd string
		if !p.done {
			pwd, _ = p.term.Pwd()
		}
		p.mu.Unlock()
		if command != "" && command != shell && command != pty.DefaultCommand() {
			fields = append(fields, "command = "+luaQuote(command))
		}
		if dir := pwdPath(pwd, localHost()); dir != "" {
			fields = append(fields, "cwd = "+luaQuote(dir))
		}
		if len(fields) == 0 {
			return "squish.layout.pane{}"
		}
		return "squish.layout.pane{ " + strings.Join(fields, ", ") + " }"
	}
	return "squish.layout.pane{}"
}

// trimFloat writes a ratio briefly: 0.7, not 0.700000.
func trimFloat(f float64) string {
	s := fmt.Sprintf("%.4f", f)
	s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	if s == "" || s == "0" {
		return "0.0001"
	}
	return s
}

// luaQuote is s as a Lua string literal.
func luaQuote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"', '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if r < 0x20 {
				fmt.Fprintf(&b, `\%d`, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}
