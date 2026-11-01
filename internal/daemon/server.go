// Package daemon is squish: a daemon that owns ptys and the terminal
// state of each (internal/vt), so they outlive the windows showing them.
//
// Panes (a pty and its terminal) are arranged in tabs, each a layout
// tree, and tabs are grouped in workspaces. A window attaches a whole
// workspace, beside any other windows showing it, and draws the frames
// of each pane's screen the daemon sends (framing.go), sending input
// back as events (events.go). The daemon owns the structure and the
// focus; a window mirrors them, asking for changes (rpc.go) and
// applying the workspace.changed events that come back.
package daemon

import (
	"cmp"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"slices"
	"sync"
	"time"

	"github.com/aldehir/squish/internal/config"
	"github.com/aldehir/squish/internal/pty"
	"github.com/aldehir/squish/internal/rpc"
	"github.com/aldehir/squish/internal/vt"
)

// Server holds the workspaces and serves clients.
//
// Its lock guards the structure: workspaces, tabs, their trees and
// focus, which panes exist, and who views what. It's taken before a
// pane's lock, never inside one.
type Server struct {
	vt    *vt.Runtime
	spawn func(pty.Options) (pty.Pty, error)
	log   *slog.Logger
	idle  time.Duration
	// The state directory keeps model.json (state.go), which a stop
	// with save leaves for the next daemon (keepState); build is this
	// executable's, args what it was started with.
	stateDir  string
	build     rpc.Build
	args      []string
	started   time.Time
	model     modelWriter
	keepState bool

	mu sync.Mutex
	// Ids are paths (rpc.TabID, rpc.PaneID): the daemon numbers
	// workspaces and scripts, a workspace its tabs, a tab its panes,
	// each from a counter that never reuses a number while its owner
	// lives.
	nextWS     uint32
	nextScript uint32
	workspaces map[uint32]*workspace
	tabs       map[TabID]*tab
	panes      map[PaneID]pane
	// moved forwards the id a pane had before it moved tabs to its
	// current one, for as long as it lives: a shell's SQUISH_PANE still
	// finds it. One hop: a pane that moves again rewrites its entries.
	moved   map[PaneID]PaneID
	conns   map[*conn]struct{}
	scripts map[uint32]*script
	hosts   hostTable
	idleT   *time.Timer
	idleC   chan struct{} // closed when the idle timer fires
	stopped bool          // daemon.stop was called
	stopC   chan struct{} // closed once its caller has the reply

	// The config (config.go): the file, what it last loaded as (nil
	// until one loads), and why the last evaluation failed, if it did.
	configPath   string
	config       *config.Config
	configErrors []string
	watch        time.Duration

	// The file picker's scans (find.go), by directory.
	findMu sync.Mutex
	finds  map[string]*findCache
}

// Options configure a Server.
type Options struct {
	// Spawn starts a pane's child; pty.Start if nil.
	Spawn func(pty.Options) (pty.Pty, error)
	Log   *slog.Logger
	// Idle is how long Serve waits with no workspaces, no clients, and
	// no hosts before returning. Zero waits forever.
	Idle time.Duration
	// Hosts configures connecting to SSH hosts (Windows).
	Hosts HostOptions
	// Config is the init.lua to evaluate at start (config.Path());
	// empty evaluates nothing, and config.reload stays empty.
	Config string
	// Watch is how often Serve looks at the config's files for a change
	// that reloads it (watch.go); zero never looks.
	Watch time.Duration
	// StateDir is where model.json goes (state.go), and what a daemon
	// starting there restores; empty keeps no state.
	StateDir string
	// Args are the arguments the daemon was started with, for the
	// daemon replacing it to run with the same.
	Args []string
}

// defaultSize is a pane's size when nothing says otherwise.
var defaultSize = Size{Cols: 80, Rows: 24}

func NewServer(rt *vt.Runtime, opts Options) (*Server, error) {
	if opts.Spawn == nil {
		opts.Spawn = pty.Start
	}
	if opts.Log == nil {
		opts.Log = slog.New(slog.DiscardHandler)
	}
	s := &Server{
		vt:         rt,
		spawn:      opts.Spawn,
		log:        opts.Log,
		idle:       opts.Idle,
		workspaces: map[uint32]*workspace{},
		tabs:       map[TabID]*tab{},
		panes:      map[PaneID]pane{},
		moved:      map[PaneID]PaneID{},
		conns:      map[*conn]struct{}{},
		scripts:    map[uint32]*script{},
		hosts:      newHostTable(opts.Hosts),
		idleC:      make(chan struct{}),
		stopC:      make(chan struct{}),
		configPath: opts.Config,
		watch:      opts.Watch,
		stateDir:   opts.StateDir,
		build:      CurrentBuild(),
		args:       opts.Args,
		started:    time.Now(),
	}
	if opts.Config != "" {
		s.loadConfig()
	}
	return s, nil
}

// Serve accepts clients on l until l fails, the server has been idle for
// Options.Idle, or daemon.stop is called, when it closes l and returns
// nil; after a stop it kills every terminal first.
func (s *Server) Serve(l net.Listener) error {
	// Restore what the last daemon left, if anything, before serving
	// anyone: a client then finds the workspaces there.
	if s.stateDir != "" {
		m, err := readModel(s.stateDir)
		if err != nil {
			s.log.Error("not restoring", "err", err)
		} else if m != nil {
			s.restore(m)
		}
		s.autostartWorkspaces(m != nil && len(m.Workspaces) > 0)
		go s.cleanBuilds()
	}
	s.mu.Lock()
	s.checkIdleLocked()
	s.mu.Unlock()
	if s.watch > 0 && s.configPath != "" {
		stop := make(chan struct{})
		defer close(stop)
		s.watchConfig(s.watch, stop)
	}
	errc := make(chan error, 1)
	go func() {
		for {
			rw, err := l.Accept()
			if err != nil {
				errc <- err
				return
			}
			go s.handle(rw)
		}
	}()
	select {
	case err := <-errc:
		return err
	case <-s.idleC:
		s.log.Info("idle; exiting")
		l.Close()
		s.clearState()
		return nil
	case <-s.stopC:
		s.log.Info("stopped; exiting", "keeping state", s.keepState)
		l.Close()
		s.Close()
		if !s.keepState {
			s.clearState()
		}
		return nil
	}
}

// daemonStop ends the daemon. The reply goes out first, and Serve
// returns once the caller's connection has written it (or a second has
// passed), so `squish stop` hears back before the pipe goes away. With
// save, model.json is written as things are and kept for the daemon
// that starts next (an upgrade), and every client is told
// daemon.restarting first, so it reconnects rather than giving up.
func (s *Server) daemonStop(cl *callCtx, p rpc.DaemonStopParams) (rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stopped {
		cl.reply(rpc.Empty{})
		return rpc.Empty{}, nil
	}
	if p.Save && s.stateDir != "" {
		if err := s.writeModel(s.modelLocked()); err != nil {
			return rpc.Empty{}, rpc.Errorf(rpc.CodeFailed, "saving the model: %v", err)
		}
		s.keepState = true
		restarting := notify(rpc.EvDaemonRestarting, rpc.DaemonRestartingParams{Build: p.Build})
		for c := range s.conns {
			if c != cl.c {
				c.sendForce(NoPane, restarting)
			}
		}
		s.log.Info("stopping to be replaced", "by", p.Build.ID, "panes", len(s.panes))
	}
	cl.reply(rpc.Empty{})
	s.stopped = true
	if cl.c == nil {
		close(s.stopC)
		return rpc.Empty{}, nil
	}
	cl.c.closeAfterFlush()
	go func() {
		select {
		case <-cl.c.done:
		case <-time.After(time.Second):
		}
		close(s.stopC)
	}()
	return rpc.Empty{}, nil
}

// checkIdleLocked starts the idle timer when nothing is left, and stops
// it otherwise.
func (s *Server) checkIdleLocked() {
	if s.idle == 0 {
		return
	}
	idle := s.idleLocked()
	switch {
	case idle && s.idleT == nil:
		s.idleT = time.AfterFunc(s.idle, func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			if s.idleT != nil && s.idleLocked() {
				close(s.idleC)
			}
		})
	case !idle && s.idleT != nil:
		s.idleT.Stop()
		s.idleT = nil
	}
}

// idleLocked says whether nothing keeps the daemon alive.
func (s *Server) idleLocked() bool {
	return len(s.workspaces) == 0 && len(s.panes) == 0 && len(s.conns) == 0 && len(s.scripts) == 0 && s.hostsActiveLocked() == 0
}

func (s *Server) handle(rw io.ReadWriteCloser) {
	r := NewReader(rw)
	f, err := r.Read()
	if err != nil {
		rw.Close()
		return
	}
	m, err := Decode(f)
	if b, ok := m.(*Bridge); ok && err == nil {
		s.bridge(rw, r, b)
		return
	}
	c := newConn(rw, s.log)
	if !s.handshake(c, m, err) {
		c.closeAfterFlush()
		return
	}
	s.mu.Lock()
	s.conns[c] = struct{}{}
	s.checkIdleLocked()
	s.mu.Unlock()
	defer func() {
		c.close()
		s.mu.Lock()
		for _, ws := range c.viewing {
			s.releaseLocked(ws, c, "")
		}
		delete(s.conns, c)
		s.hostClientGoneLocked(c)
		s.scriptClientGoneLocked(c)
		s.checkIdleLocked()
		s.mu.Unlock()
	}()
	for {
		f, err := r.Read()
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) && !errors.Is(err, os.ErrClosed) {
				s.log.Info("client read", "err", err)
			}
			return
		}
		m, err := Decode(f)
		if err != nil {
			s.log.Warn("bad frame", "err", err)
			if errors.Is(err, ErrUnknownType) || errors.Is(err, ErrBadJSON) {
				continue
			}
			return
		}
		s.dispatch(c, f.ID, m)
	}
}

// handshake answers the first frame, decoded as m (or err), which must
// be a Hello.
func (s *Server) handshake(c *conn, m Message, err error) bool {
	hello, ok := m.(*Hello)
	if err != nil || !ok {
		c.sendForce(NoPane, &Error{Message: "expected hello"})
		return false
	}
	c.sendForce(NoPane, &HelloReply{
		Version:     Version,
		PID:         uint32(os.Getpid()),
		FrameLayout: vt.FrameLayout(),
		Build:       s.build,
	})
	if hello.Version != Version {
		c.sendForce(NoPane, &Error{Message: fmt.Sprintf("squish speaks version %d, not %d", Version, hello.Version)})
		return false
	}
	c.interval = defaultFrameInterval
	if hello.FrameInterval != 0 {
		c.interval = time.Duration(hello.FrameInterval) * time.Microsecond
	}
	return true
}

func (s *Server) dispatch(c *conn, id PaneID, m Message) {
	switch m := m.(type) {
	case *Call:
		s.call(c, m.Request)
	case *Ack:
		if p, ok := s.pane(id).(*Pane); ok {
			p.ack(c, m.Seq)
		}
	case *Event:
		if p, ok := s.pane(id).(*Pane); ok {
			p.event(c, m.Data)
		}
	case *Resize:
		if p := s.pane(id); p != nil {
			p.resize(c, m.Size)
		}
	default:
		s.log.Warn("unexpected message", "type", m.Type())
	}
}

// writeError writes an Error straight to a connection that has no conn
// yet, and closes it once the client has hung up or a moment has
// passed: closing with its Hello unread would reset a TCP connection
// and lose the Error.
func writeError(rw io.ReadWriteCloser, msg string) {
	if b, err := Encode(NoPane, &Error{Message: msg}); err == nil {
		rw.Write(b)
	}
	if c, ok := rw.(net.Conn); ok {
		c.SetReadDeadline(time.Now().Add(time.Second))
		io.Copy(io.Discard, c)
	}
	rw.Close()
}

func (s *Server) pane(id PaneID) pane {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.paneLocked(id)
}

// paneLocked finds a pane by its id, or by one it had before moving
// tabs.
func (s *Server) paneLocked(id PaneID) pane {
	if p := s.panes[id]; p != nil {
		return p
	}
	if now, ok := s.moved[id]; ok {
		return s.panes[now]
	}
	return nil
}

// startPane starts a child and its terminal for pane id, outside the
// server's lock: spawning takes a while. The caller registers it
// (addPaneLocked), or closes it if what it was for is gone by then. A
// browser has neither: its spec is all there is.
func (s *Server) startPane(id PaneID, spec *rpc.PaneSpec, size Size) (*started, error) {
	if spec.Kind == rpc.PaneBrowser {
		return &started{id: id, spec: spec}, nil
	}
	// The config's shell, if it names one, is run as given; the
	// platform's default is the pty's to pick, and named for the pane.
	command := spec.Command
	if command == "" {
		command = s.shellCommand()
	}
	run := command
	if command == "" {
		command = pty.DefaultCommand()
	}
	if size.Cols == 0 || size.Rows == 0 {
		size.Cols, size.Rows = defaultSize.Cols, defaultSize.Rows
	}
	term, err := s.vt.New(size.Cols, size.Rows)
	if err != nil {
		return nil, err
	}
	if err := term.Resize(size.Cols, size.Rows, size.CellW, size.CellH); err != nil {
		term.Close()
		return nil, err
	}
	opts := pty.Options{
		Command: run,
		Dir:     spec.Cwd,
		Env:     paneEnv(id, spec),
		Cols:    size.Cols,
		Rows:    size.Rows,
		Width:   uint32(size.Cols) * size.CellW,
		Height:  uint32(size.Rows) * size.CellH,
	}
	st := &started{id: id, spec: spec, command: command, run: run, size: size, term: term}
	p, err := s.spawn(opts)
	if err != nil {
		term.Close()
		return nil, err
	}
	st.pty = p
	return st, nil
}

func (s *Server) list() *rpc.WorkspaceListResult {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := &rpc.WorkspaceListResult{Workspaces: []rpc.WorkspaceDesc{}, Panes: []rpc.PaneDesc{}}
	for _, ws := range s.workspaces {
		out.Workspaces = append(out.Workspaces, ws.desc())
		for _, t := range ws.tabs {
			for _, id := range t.root.Panes() {
				if p := s.panes[id]; p != nil {
					out.Panes = append(out.Panes, p.desc())
				}
			}
		}
	}
	slices.SortFunc(out.Workspaces, func(a, b rpc.WorkspaceDesc) int { return cmp.Compare(a.ID, b.ID) })
	return out
}

// Close kills every terminal, at once: a holder's Close waits for its
// child to go.
func (s *Server) Close() {
	s.closeFinds()
	s.mu.Lock()
	ps := make([]*Pane, 0, len(s.panes))
	for _, p := range s.panes {
		if p, ok := p.(*Pane); ok {
			ps = append(ps, p)
		}
	}
	s.mu.Unlock()
	var wg sync.WaitGroup
	for _, p := range ps {
		wg.Go(func() { p.pty.Close() })
	}
	wg.Wait()
}
