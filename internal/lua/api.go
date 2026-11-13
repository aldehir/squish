package lua

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"

	glua "github.com/yuin/gopher-lua"

	"github.com/aldehir/squish/internal/rpc"
)

// The squish table, as Doc says; its shape is Rex's with the nouns
// renamed. Doc is `squish help lua`, kept here with what it describes.
const Doc = `Scripts run in the daemon (squish do) with gopher-lua, a Lua 5.1. The
libraries are base, package, table, string, math, coroutine, debug, and
os without exit; there is no io, and print goes to the console that ran
the script. One state per run. The chunk, and each call of a hook,
timer, or process callback, is a task: one runs Lua at a time, and a
task that blocks (sleep, wait, exec, a process's wait) lets the others
run meanwhile, so Lua never runs concurrently with itself. A script
ends when its chunk has returned and no hook or timer is live, when it
calls squish.stop, or when it's cancelled (its tasks end at their next
instruction or blocking call).

THE SQUISH TABLE

  squish.args                table of the key=value arguments (empty if none)
  squish.workspace_id        what the script runs for, or nil: a number,
  squish.tab_id, squish.pane_id  "w.t", and "w.t.p"; read at call time, so a
                             script may set them to retarget
  squish.call(method, params) any method by wire name; params a table or nil
  squish.workspace.<m>{...}  workspace.<m> with id filled from workspace_id
                             (not for list); new gets attach from it instead,
                             so the windows on the script's workspace open the
                             new one (attach = false leaves it detached; another
                             id names another workspace's windows); focus with
                             neither tab nor pane gets pane from pane_id
  squish.tab.<m>{...}        tab.<m>; tab.new gets workspace, the rest id
                             from tab_id
  squish.pane.<m>{...}       pane.<m>; split, move, navigate, and visited get
                             pane, the rest id from pane_id: so
                             squish.pane.navigate{url = "..."} sends this
                             script's browser pane there
  squish.workspace.open{name, attach?, beside?}
                             the workspace named name, open or made from
                             init.lua's squish.workspace.define of it (below)
  squish.workspace.export{id} {lua}: the workspace as a squish.workspace.define
                             call, for init.lua (squish ws export)
  squish.id.parse(id)        {workspace, tab, pane} from 1, "1.2", or "1.2.3"
                             (the parts it has); nil, err for anything else
  squish.id.tab(w, t)        "w.t" and "w.t.p" from numbers
  squish.id.pane(w, t, p)
  squish.layout.pane{command, cwd, env}
                             a leaf for tabs in workspace.new or layout in tab.new
  squish.layout.browser{url} a browser leaf: a pane a window's browser fills,
                             showing url (which it needs)
  squish.layout.horizontal([ratio,] a, b, ...)
                             side by side (a row split); ratio is a's share (0 to
                             1), the rest share what's left equally; no ratio
                             divides equally
  squish.layout.vertical([ratio,] a, b, ...)
                             stacked (a column split); same rule
  squish.json.encode(v)      JSON; return nil, err on failure
  squish.json.decode(s)
  squish.log(...)            a line to the daemon's log and the script's stderr;
                             arguments joined by tabs like print
  squish.stop([result])      ends the run successfully, with result as its
                             return value
  squish.invoke(name, args)  runs an action init.lua defined (below), for this
                             script's pane, and returns what it returned, or
                             nil, message, code; its output is the script's

Calls return the result table, or nil, message, code (see squish help
methods for the codes). Wrap in assert(...) when failure should end the
script. The namespaces are metatables: any method the daemon has works,
including ones added later, without a Lua-side list.

EVENTS, WAITING, TIMERS, PROCESSES

  squish.on(event, fn)       fn(ctx, ev) runs for each event (a name from squish
                             help events, "pane.*" for a group, or "*"), in a
                             task of its own; ev is the event's params. Returns
                             a handle: h:cancel() ends it, h:active() says. A
                             live hook keeps a script running after its chunk
                             returns; cancel it or call squish.stop to end.
  squish.wait(event, filter, timeout)
                             blocks until the next such event whose fields
                             equal filter's (a table, or nil for any): a key
                             names a field of ev, except workspace_id, tab_id,
                             and pane_id, which name what the event is about
                             (a pane's names its tab and workspace too).
                             Returns ev, or nil, "timeout" after timeout
                             seconds (none waits as long as the run lasts).
  squish.sleep(seconds)      blocks for that long
  squish.after(seconds, fn)  fn(ctx) runs once after the delay; a handle as on
  squish.every(seconds, fn)  and again after each delay until cancelled
  squish.exec(argv, opts)    runs a program on the daemon's host to its end:
                             argv a list of strings (the program first), opts
                             {cwd, env = {VAR = "value"}, stdin = "text",
                             timeout = seconds}. Returns {status, ok, stdout,
                             stderr}, or nil, err if it couldn't start or timed
                             out (it's killed then).
  squish.exec.start(argv, opts)
                             starts one and returns a handle: p.pid, p:running(),
                             p:wait([timeout]) (the result above, or nil,
                             "timeout"), p:kill(), and with opts.stdin = true,
                             p:write(text) and p:close_stdin(). opts.stdout and
                             opts.stderr may be functions that get each piece of
                             output as it comes (then wait's are empty). A run
                             ending kills the processes it started.
  squish.client.queue(name, args)
                             asks the windows on this script's workspace to
                             perform a window action with args, as if its key
                             were pressed there: copy_to_clipboard,
                             paste_from_clipboard, increase_font_size
                             {amount}, decrease_font_size, reset_font_size,
                             and the focused pane's increase_pane_font_size
                             {amount}, decrease_pane_font_size,
                             reset_pane_font_size (each window's own pane).
                             Every window showing the workspace does, so one
                             that changes the workspace (new_split, new_tab,
                             toggle_split_zoom, ...) is refused: squish.pane.split
                             and the rest do that once, for the pane named

ctx for a hook is {workspace_id, tab_id, pane_id, origin = "event", event}:
what the event is about, as filter sees it; for a timer, what the
script runs for and origin = "timer". Hooks and timers run for the ids
the script had when they were set. An error in a hook ends the script
(in init.lua, it's logged). An event nobody is waiting for yet isn't
kept: set the hook, or start the wait, before causing the event where
it matters.

INIT.LUA

The daemon evaluates init.lua (squish config path; SQUISH_CONFIG overrides)
when it starts and on squish config reload, in a state of its own that
lives as long as the config: the functions the file hands to bind and
action are called again from it for every key press and squish do. It
has the squish table above (ids are nil at the top level) and these,
which are for the top level only:

  squish.config{...}         the settings, one table, merged over earlier
                             calls key by key (lists replace). The daemon takes
                             shell.command (what a pane runs when nothing says)
                             and host.proxy (false: no SOCKS proxy over a host's
                             connection; the proxy is loopback-only and has no
                             auth, so any local program can use the tunnel;
                             read when a host connects, so a reload changes
                             only the hosts that connect after it);
                             each window takes what it understands and ignores
                             the rest (squish-gui: font, theme, colors, window,
                             chrome, pane, selection, clipboard, ssh,
                             browser). daemon = {upgrade = "ask"|"never"}
                             says whether a window offers to replace this
                             daemon when it runs an older build than the
                             window's (an icon by the host; the layout comes
                             back, the programs end); squish upgrade always
                             can.
                             Values must be JSON: no functions.
  squish.bind(key, action[, args])
                             key (a chord: "ctrl+shift+d"; modifiers ctrl,
                             shift, alt, super/win, then a key name, or a
                             notch of the wheel: wheel_up, wheel_down,
                             wheel_left, wheel_right, which bind alone, never
                             in a sequence; or keys pressed one after
                             another, joined by >: "ctrl+b>c") runs a window
                             action by name with
                             args (squish-gui's: new_tab, new_split {direction},
                             close_surface, next_tab, previous_tab, goto_split
                             {direction}, resize_split {direction, amount},
                             equalize_splits, toggle_split_zoom,
                             toggle_fullscreen (F11: the panes alone over the
                             whole monitor, no title bar or sidebar), the floating
                             tabs' float_pane, float_tab (picks a tab in the
                             palette), dock_float, toggle_floats, and
                             focus_float, which have no keys by default,
                             toggle_command_palette, pick_file (a fuzzy path
                             picker at the cursor, ctrl+i), start_search,
                             navigate_search {direction = "next"|"previous"},
                             end_search, copy_mode, copy_to_clipboard,
                             paste_from_clipboard,
                             increase_font_size {amount}, decrease_font_size
                             {amount}, reset_font_size, the window's size and
                             ctrl+wheel's; increase_pane_font_size {amount},
                             decrease_pane_font_size {amount},
                             reset_pane_font_size, points on the window's for
                             the focused pane, or for a wheel binding the one
                             under the pointer, ctrl+shift+wheel's), or else
                             an action of this file by name. A wheel binding
                             takes the wheel from the program under it:
                             unbind "ctrl+wheel_up" and the rest for a program
                             that zooms on ctrl+wheel. A later bind of the key
                             replaces the earlier, and the window's default for
                             it. A key runs an action or starts a sequence,
                             never both: the later binding hides the earlier
                             (bind "ctrl+b>c" and ctrl+b alone no longer
                             reaches the program; bind "ctrl+b>ctrl+b" to a
                             function that writes it). The window keeps the
                             keys of a sequence; Escape ends one, as does a key
                             that's not in it, or a reload. A sequence written
                             "repeat:ctrl+b>h" keeps its earlier keys pressed
                             once it runs, for half a second after each press,
                             so its last key again runs it again (tmux's
                             bind -r: resizing a pane by holding ctrl+b>shift+h
                             then tapping shift+h); a key that's no repeat ends
                             that and does what it does alone.
  squish.bind(key, fn)       key runs fn(ctx, args) in the daemon; a function
                             binding always consumes its key
  squish.unbind(key)         key does nothing, even if the window binds it;
                             exactly that key: unbinding "ctrl+b" leaves
                             "ctrl+b>c" bound
  Search                     ctrl+shift+f (start_search) opens a card at the
                             pane's top right; the daemon searches the screen
                             and scrollback as the needle is typed, marks every
                             match (colors.search_match, the palette's yellow
                             by default), and makes the current one the
                             selection; Enter and shift+Enter step, Escape
                             closes.
  squish.bind("copy-mode:" .. key, action)
                             a key of copy mode (the copy_mode action,
                             ctrl+shift+m: tmux's copy mode with its vi keys,
                             in the daemon). It shows a snapshot of the pane
                             and its scrollback, taken as it starts; output
                             goes on unseen until q, ctrl+c, or a copy leaves.
                             tmux's keys: Space begins a selection, v and
                             ctrl+v make it a rectangle, V selects lines,
                             Enter copies and leaves, Escape clears; / and ?
                             open the search card as a prompt, which searches
                             on Enter from the cursor (an all-lowercase needle
                             ignores case; up recalls the last), and n and N
                             repeat; * and # search the word under the cursor.
                             key is the character the key types ("v", "G",
                             "$"), a name (escape, enter, space, tab,
                             backspace, up, down, left, right, home, end,
                             pageup, pagedown, delete, insert), or "ctrl+"
                             with one ("ctrl+v"); digits are counts. action
                             is one of tmux's copy-mode commands, with
                             underscores or tmux's hyphens (copy-pipe names
                             copy): begin_selection, select_line,
                             rectangle_toggle, other_end, clear_selection,
                             cancel, copy_selection,
                             copy_selection_and_cancel, copy_end_of_line,
                             copy_end_of_line_and_cancel, cursor_left,
                             cursor_right, cursor_up, cursor_down,
                             start_of_line, back_to_indentation, end_of_line,
                             top_line, middle_line, bottom_line, history_top,
                             history_bottom, next_word, next_word_end,
                             previous_word, next_space, next_space_end,
                             previous_space, next_paragraph,
                             previous_paragraph, next_matching_bracket,
                             previous_matching_bracket, page_up, page_down,
                             halfpage_up, halfpage_down, scroll_up,
                             scroll_down, scroll_middle, jump_forward,
                             jump_backward, jump_to_forward,
                             jump_to_backward, jump_again, jump_reverse,
                             search_forward, search_backward, search_again,
                             search_reverse, search_word_forward,
                             search_word_backward. squish.unbind("copy-mode:"
                             .. key) drops a default. The usual tmux.conf
                             setup is squish.bind("copy-mode:v",
                             "begin-selection") and squish.bind("copy-mode:y",
                             "copy-selection-and-cancel").
  squish.action{name, title, args, run}
                             an action: squish do <name> key=value..., a bound
                             key, and squish.invoke run run(ctx, args), and print
                             what it returns. args is a spec for listing and
                             for converting the CLI's strings: {n = "number",
                             on = "boolean", file = "string"}.
  squish.workspace.define{name, tabs, autostart}
                             a workspace by name: tabs is a list of layouts as
                             workspace.new takes them (squish.layout.pane and
                             the rest), which workspace.open{name = ...} (squish
                             ws open, the palette's "Open workspace") makes
                             when none of that name is open; with autostart
                             = true it opens when the daemon starts with
                             nothing to restore. A later define of the name
                             replaces the earlier. squish ws export writes an
                             open workspace back as one.

ctx is {workspace_id, tab_id, pane_id, origin}: the pane the action runs
for (a window's focused pane, squish do's SQUISH_PANE, a script's own),
also filled into squish.pane_id and the rest while it runs; origin is key,
cli, script, or api. require, dofile, and loadfile find files beside
init.lua. A file that fails leaves the last good config in place (the
daemon's log and squish config show say why); squish config check tries
one without applying it.

  squish.config{
    font = { family = { "Cascadia Code", "Consolas" }, size = 12, antialias = "grayscale" },
    theme = "Catppuccin Mocha",      -- a bundled Ghostty theme, or a file under themes/ beside init.lua
    colors = { background = "#282c34", cursor = "#ffcc00" },
    window = { padding = { x = 3, y = 3 } },
    chrome = { scale = 1, preview_delay = 100, -- ms resting on a hidden tab's row before its preview shows (0: at once)
               tabs = "sidebar" },   -- "top": the active workspace's tabs in the title bar, the sidebar lists workspaces
    pane = { gap = 10, radius = 10,  -- DIPs between panes and of their corners; 0 tiles them square
             margin = 10,           -- around the panes, to the chrome and the window's edges (unset: gap)
             padding = 10 },         -- inside each pane, around its grid, under window.padding
    fullscreen = { gap = 10, radius = 10, margin = 10, padding = 10 }, -- pane's four, fullscreen (F11); each unset takes pane's
    browser = { idle = 600 },        -- seconds a hidden browser pane stays open (0: always)
    shell = { command = "pwsh -NoLogo" },
    host = { proxy = true },         -- a SOCKS proxy per connected host (squish host ls)
    daemon = { upgrade = "ask" },    -- "never": windows don't offer to replace an older daemon
  }

  squish.workspace.define{
    name = "dev",
    autostart = true,
    tabs = {
      squish.layout.horizontal(0.7,
        squish.layout.pane{ command = "nvim", cwd = "~/src/app" },
        squish.layout.pane{ cwd = "~/src/app" }),
      squish.layout.pane{ command = "tail -f /var/log/app.log" },
    },
  }
  squish.bind("ctrl+shift+d", "new_split", { direction = "right" })
  squish.bind("ctrl+shift+t", "new_tab")
  squish.bind("ctrl+alt+l", function(ctx, args) squish.invoke("dev", { file = "app.log" }) end)
  squish.action{ name = "dev", title = "Dev layout", args = { file = "string" },
    run = function(ctx, args) return dofile("dev.lua") end }

Values cross as JSON. Numbers are doubles; workspace ids are numbers,
tab and pane ids strings, compared with ==. A table whose keys are
exactly 1..n is an array; any other table, including an empty one, is
an object. So a method that takes a list can't be given an empty table,
and nil in a table means the key is absent. Functions and cycles can't
be encoded.

Caveats: pcall catches squish.stop (it is an error under the hood). A
script is never a viewer: squish.workspace.new needs tabs; run from a
pane, the windows on that pane's workspace open the new one, otherwise
it starts detached. A script's split, tab.new, and move don't take the
focus (a window's own do). subscribe is the wire's; squish.on is a
script's. squish.config, bind, unbind, and action are init.lua's. In
init.lua, hooks and timers set at the top level live as long as that
config does (a reload ends them, and what the old config was running),
and an action may sleep, wait, and exec: another key's action runs
meanwhile.

EXAMPLES

Inspect (squish do -e '...'):

  local l = assert(squish.workspace.list{})
  for _, ws in ipairs(l.workspaces) do
    print(ws.id, ws.name, ws.attached and "attached" or "detached", #ws.tabs .. " tabs")
  end
  for _, p in ipairs(l.panes) do print("pane", p.id, p.command, p.title) end

Build a workspace from a layout (squish do dev.lua file=app.log):

  local ws = assert(squish.workspace.new{
    name = "dev",
    tabs = {
      squish.layout.horizontal(0.7,
        squish.layout.pane{ command = "nvim" },
        squish.layout.vertical(0.5,
          squish.layout.pane{ command = "tail -f " .. squish.args.file },
          squish.layout.pane{})),
      squish.layout.pane{ command = "bash", cwd = "/src", env = { EDITOR = "nvim" } },
    },
  })
  print("workspace", ws.id, "opens on tab", ws.active_tab)
  return ws.id

From inside a pane (ids default to this pane):

  local me = assert(squish.pane.info{})
  squish.log("splitting", me.id, "in", me.pwd)          -- the shell's directory, if it reports it
  local below = assert(squish.pane.split{ direction = "down", share = 3000 })  -- starts there too
  assert(squish.pane.write{ id = below.pane, text = "git status\r" })
  assert(squish.workspace.focus{ pane = below.pane })   -- its tab comes with it

Walk a tab's tree:

  local function leaves(node, out)
    if node.pane then out[#out + 1] = node.pane
    else for _, c in ipairs(node.split.children) do leaves(c.node, out) end end
    return out
  end
  local t = assert(squish.tab.info{ id = squish.tab_id })
  for _, id in ipairs(leaves(t.tree, {})) do
    print(id, assert(squish.pane.text{ id = id }).text:match("[^\n]*$"))  -- last line of each
  end

Errors and stopping early:

  local p, err, code = squish.pane.info{ id = "1.1.999" }
  if not p then squish.log("no pane:", err, code) end          -- 1000 is not found
  if #assert(squish.workspace.list{}).workspaces > 0 then squish.stop("already set up") end

Run a command below and wait for it (squish do build.lua):

  local p = assert(squish.pane.split{ direction = "down", share = 3000, command = "go build ./..." })
  local ev = squish.wait("pane.exited", { pane_id = p.pane }, 600)
  if not ev then squish.stop("still building") end
  return "exit " .. ev.status

Watch for bells until stopped (squish do --detach watch.lua; squish scripts kill <id>):

  squish.on("pane.bell", function(ctx, ev)
    local info = assert(squish.pane.info{ id = ev.id })
    squish.log("bell in", ev.id, info.title or "")
  end)
  squish.every(60, function() squish.log("still watching") end)

A browser beside this pane, following where its windows go (pane.url):

  local b = assert(squish.pane.split{ direction = "right", kind = "browser", url = "http://localhost:8080" })
  squish.on("pane.url", function(ctx, ev)
    if ev.id == b.pane then squish.log("browser at", ev.url) end
  end)
  squish.pane.navigate{ pane = b.pane, url = "http://localhost:8080/docs" }

Float this pane over its tab, as a window inside it, then minimize it
(squish.tab.dock{id = ...} makes it an ordinary tab again):

  local f = assert(squish.pane.move{ float = true })  -- or float = { over = "1.2", rect = { x = 0, y = 0, w = 5000, h = 10000 } }
  local id = squish.id.parse(f.pane)
  squish.tab.float{ id = squish.id.tab(id.workspace, id.tab), minimized = true }
  squish.on("tab.docked", function(ctx, ev) squish.log(ev.id, "docked") end)

Shell out (on the daemon's host):

  local r = assert(squish.exec({ "git", "status", "--short" }, { cwd = squish.args.dir }))
  for line in r.stdout:gmatch("[^\n]+") do print(line) end`

// install sets the script's globals: the squish table, and print.
func (r *Runner) install(ctx Context) {
	L := r.L
	squish := L.NewTable()
	r.squish = squish
	args := glua.LValue(L.NewTable())
	if len(ctx.Args) > 0 {
		if v, err := fromJSON(L, ctx.Args); err == nil && v != glua.LNil {
			args = v
		}
	}
	squish.RawSetString("args", args)
	r.setIDs(idsOf(ctx.Pane))
	squish.RawSetString("call", L.NewFunction(r.luaCall))
	squish.RawSetString("invoke", L.NewFunction(r.luaInvoke))
	for _, group := range []string{"workspace", "tab", "pane"} {
		squish.RawSetString(group, r.namespace(group))
	}
	ids := L.NewTable()
	L.SetFuncs(ids, map[string]glua.LGFunction{"parse": idParse, "tab": idTab, "pane": idPane})
	squish.RawSetString("id", ids)
	layout := L.NewTable()
	L.SetFuncs(layout, map[string]glua.LGFunction{
		"pane":       layoutPane,
		"browser":    layoutBrowser,
		"horizontal": func(L *glua.LState) int { return layoutSplit(L, rpc.Row) },
		"vertical":   func(L *glua.LState) int { return layoutSplit(L, rpc.Column) },
	})
	squish.RawSetString("layout", layout)
	jsonT := L.NewTable()
	L.SetFuncs(jsonT, map[string]glua.LGFunction{"encode": jsonEncode, "decode": jsonDecode})
	squish.RawSetString("json", jsonT)
	squish.RawSetString("log", L.NewFunction(r.luaLog))
	squish.RawSetString("stop", L.NewFunction(r.luaStop))
	squish.RawSetString("on", L.NewFunction(r.luaOn))
	squish.RawSetString("wait", L.NewFunction(r.luaWait))
	squish.RawSetString("sleep", L.NewFunction(r.luaSleep))
	squish.RawSetString("after", L.NewFunction(r.luaAfter))
	squish.RawSetString("every", L.NewFunction(r.luaEvery))
	r.installHandles()
	r.installExec()
	client := L.NewTable()
	client.RawSetString("queue", L.NewFunction(r.luaClientQueue))
	squish.RawSetString("client", client)
	L.SetGlobal("squish", squish)
	L.SetGlobal("print", L.NewFunction(r.luaPrint))
}

// luaClientQueue is squish.client.queue(name, args): the windows on the
// script's workspace perform window action name with args
// (client.queue, which sends them client.action).
func (r *Runner) luaClientQueue(L *glua.LState) int {
	name := L.CheckString(1)
	params := L.NewTable()
	params.RawSetString("name", glua.LString(name))
	if args := L.OptTable(2, nil); args != nil {
		params.RawSetString("args", args)
	}
	ws := r.squish.RawGetString("workspace_id")
	if ws == glua.LNil {
		return pushError(L, "client.queue: no workspace: the script runs for no pane", 0)
	}
	params.RawSetString("workspace", ws)
	return r.call(L, rpc.ClientQueue, params)
}

// namespace is squish.<group>: a table whose missing keys become the
// methods "<group>.<key>", made on first use.
func (r *Runner) namespace(group string) *glua.LTable {
	L := r.L
	t := L.NewTable()
	mt := L.NewTable()
	mt.RawSetString("__index", L.NewFunction(func(L *glua.LState) int {
		key := L.CheckString(2)
		method := group + "." + key
		fn := L.NewFunction(func(L *glua.LState) int {
			params := L.OptTable(1, L.NewTable())
			r.fillContext(method, params)
			return r.call(L, method, params)
		})
		t.RawSetString(key, fn)
		L.Push(fn)
		return 1
	}))
	L.SetMetatable(t, mt)
	return t
}

// fillContext puts the script's ids into the params a method takes
// them in, where the script left them out: a workspace method's id,
// workspace.new's attach (so the windows on the script's workspace open
// the new one; attach = false leaves it detached, true asks for the
// default), workspace.focus's pane (or tab, with no pane to fill),
// tab.new's workspace, a pane method's id, and the pane a split or
// move starts from, or a browser's navigate and visited name.
func (r *Runner) fillContext(method string, params *glua.LTable) {
	var field, from string
	group, name, _ := strings.Cut(method, ".")
	switch group {
	case "workspace":
		switch name {
		case "list":
			return
		case "new":
			field, from = "attach", "workspace_id"
			switch params.RawGetString(field) {
			case glua.LFalse:
				params.RawSetString(field, glua.LNil)
				return
			case glua.LTrue:
				params.RawSetString(field, glua.LNil)
			}
		case "focus":
			if params.RawGetString("tab") != glua.LNil || params.RawGetString("pane") != glua.LNil {
				return
			}
			field, from = "pane", "pane_id"
			if r.squish.RawGetString(from) == glua.LNil {
				field, from = "tab", "tab_id"
			}
		default:
			field, from = "id", "workspace_id"
		}
	case "tab":
		if name == "new" {
			field, from = "workspace", "workspace_id"
		} else {
			field, from = "id", "tab_id"
		}
	case "pane":
		if name == "split" || name == "move" || name == "navigate" || name == "visited" {
			field, from = "pane", "pane_id"
		} else {
			field, from = "id", "pane_id"
		}
	default:
		return
	}
	if params.RawGetString(field) != glua.LNil {
		return
	}
	if id := r.squish.RawGetString(from); id != glua.LNil {
		params.RawSetString(field, id)
	}
}

// luaCall is squish.call(method, params).
func (r *Runner) luaCall(L *glua.LState) int {
	method := L.CheckString(1)
	return r.call(L, method, L.OptTable(2, nil))
}

// call runs method with params and pushes its result, or nil, the
// error's message, and its code.
func (r *Runner) call(L *glua.LState, method string, params *glua.LTable) int {
	var raw json.RawMessage
	if params != nil {
		b, err := toJSON(params)
		if err != nil {
			return pushError(L, fmt.Sprintf("%s: params: %v", method, err), 0)
		}
		raw = b
	}
	result, err := r.host.Call(method, raw)
	return pushResult(L, method, result, err)
}

// luaInvoke is squish.invoke(name, args): an action of the config file,
// run by the daemon, with what it returned.
func (r *Runner) luaInvoke(L *glua.LState) int {
	name := L.CheckString(1)
	var raw json.RawMessage
	if args := L.OptTable(2, nil); args != nil {
		b, err := toJSON(args)
		if err != nil {
			return pushError(L, fmt.Sprintf("invoke %s: args: %v", name, err), 0)
		}
		raw = b
	}
	// A nested call (the config's own) runs in the state this was
	// called from, which may be a coroutine of the task's.
	t := r.current
	saved := t.callL
	t.callL = L
	result, err := r.host.Invoke(name, raw)
	t.callL = saved
	return pushResult(L, "invoke "+name, result, err)
}

// pushResult pushes what a call to the host returned: its result as a
// Lua value, or nil, the error's message, and its code.
func pushResult(L *glua.LState, what string, result json.RawMessage, err error) int {
	if err != nil {
		var rerr *rpc.Error
		if errors.As(err, &rerr) {
			return pushError(L, rerr.Message, rerr.Code)
		}
		return pushError(L, err.Error(), 0)
	}
	if len(result) == 0 {
		L.Push(glua.LNil)
		return 1
	}
	v, err := fromJSON(L, result)
	if err != nil {
		return pushError(L, fmt.Sprintf("%s: result: %v", what, err), 0)
	}
	L.Push(v)
	return 1
}

func pushError(L *glua.LState, msg string, code int) int {
	L.Push(glua.LNil)
	L.Push(glua.LString(msg))
	if code != 0 {
		L.Push(glua.LNumber(code))
		return 3
	}
	return 2
}

// luaPrint is print: a line on stdout.
func (r *Runner) luaPrint(L *glua.LState) int {
	r.output(Stdout, line(L)+"\n")
	return 0
}

// luaLog is squish.log(...): a line for the daemon's log, and on the
// task's own stderr if it has one.
func (r *Runner) luaLog(L *glua.LState) int {
	text := line(L)
	r.host.Log(text)
	if t := r.current; t != nil && t.out != nil {
		t.out(Stderr, text+"\n")
	}
	return 0
}

// line joins the arguments as print does, with tabs.
func line(L *glua.LState) string {
	var b strings.Builder
	for i := 1; i <= L.GetTop(); i++ {
		if i > 1 {
			b.WriteByte('\t')
		}
		b.WriteString(L.ToStringMeta(L.Get(i)).String())
	}
	return b.String()
}

// luaStop is squish.stop([result]): the run ends, successfully, with
// result as what it returned.
func (r *Runner) luaStop(L *glua.LState) int {
	if L.GetTop() > 0 {
		r.current.stopResult = L.Get(1)
	}
	L.Error(r.stop, 0)
	return 0
}

// idParse is squish.id.parse(id): the parts of a workspace, tab, or
// pane id as {workspace, tab, pane}, the ones it has; or nil and why
// not.
func idParse(L *glua.LState) int {
	var text string
	switch v := L.Get(1).(type) {
	case glua.LNumber:
		text = numberString(float64(v))
	case glua.LString:
		text = string(v)
	default:
		return pushError(L, "an id is a number or a string", 0)
	}
	parts := strings.Split(text, ".")
	if len(parts) > 3 {
		return pushError(L, fmt.Sprintf("%q isn't an id", text), 0)
	}
	out := L.NewTable()
	for i, name := range []string{"workspace", "tab", "pane"} {
		if i >= len(parts) {
			break
		}
		n, err := strconv.ParseUint(parts[i], 10, 32)
		if err != nil || n == 0 {
			return pushError(L, fmt.Sprintf("%q isn't an id", text), 0)
		}
		out.RawSetString(name, glua.LNumber(n))
	}
	L.Push(out)
	return 1
}

// idTab is squish.id.tab(workspace, tab): "w.t".
func idTab(L *glua.LState) int {
	id := rpc.TabID{WS: idPart(L, 1), N: idPart(L, 2)}
	L.Push(glua.LString(id.String()))
	return 1
}

// idPane is squish.id.pane(workspace, tab, pane): "w.t.p".
func idPane(L *glua.LState) int {
	id := rpc.PaneID{WS: idPart(L, 1), Tab: idPart(L, 2), N: idPart(L, 3)}
	L.Push(glua.LString(id.String()))
	return 1
}

// idPart is argument i of an id: a positive integer.
func idPart(L *glua.LState, i int) uint32 {
	n := L.CheckNumber(i)
	if n <= 0 || n != glua.LNumber(uint32(n)) {
		L.ArgError(i, "an id's parts are positive integers")
	}
	return uint32(n)
}

// layoutPane is squish.layout.pane{command, cwd, env}: a leaf of a
// layout tree, in the form tab.new and workspace.new take.
func layoutPane(L *glua.LState) int {
	spec := L.OptTable(1, L.NewTable())
	leaf := L.NewTable()
	leaf.RawSetString("pane", spec)
	L.Push(leaf)
	return 1
}

// layoutBrowser is squish.layout.browser{url}: a leaf whose pane is a
// browser. It copies the table, so one reused for squish.layout.pane
// stays a terminal's.
func layoutBrowser(L *glua.LState) int {
	spec := L.NewTable()
	L.OptTable(1, L.NewTable()).ForEach(spec.RawSet)
	spec.RawSetString("kind", glua.LString(rpc.PaneBrowser))
	leaf := L.NewTable()
	leaf.RawSetString("pane", spec)
	L.Push(leaf)
	return 1
}

// layoutSplit is squish.layout.horizontal(ratio, a, b, ...) or vertical:
// a split along axis whose first child takes ratio of it and the rest
// share what's left equally; with no ratio, all share equally.
// horizontal lays its children side by side (a row), vertical stacks
// them (a column).
func layoutSplit(L *glua.LState, axis rpc.Axis) int {
	first := 1
	ratio := -1.0
	if n, ok := L.Get(1).(glua.LNumber); ok {
		ratio = float64(n)
		first = 2
		if ratio <= 0 || ratio >= 1 {
			L.ArgError(1, "ratio is between 0 and 1")
			return 0
		}
	}
	n := L.GetTop() - first + 1
	if n < 2 {
		L.RaiseError("a split needs at least two children")
		return 0
	}
	shares := make([]int, n)
	if ratio >= 0 {
		shares[0] = int(math.Round(ratio * rpc.Whole))
		left := rpc.Whole - shares[0]
		for i := 1; i < n; i++ {
			shares[i] = left / (n - 1)
		}
		shares[n-1] += left - shares[n-1]*(n-1)
	}
	children := L.NewTable()
	for i := 0; i < n; i++ {
		child := L.NewTable()
		if shares[i] != 0 {
			child.RawSetString("share", glua.LNumber(shares[i]))
		}
		child.RawSetString("node", L.CheckTable(first+i))
		children.Append(child)
	}
	split := L.NewTable()
	split.RawSetString("axis", glua.LString(axis.String()))
	split.RawSetString("children", children)
	node := L.NewTable()
	node.RawSetString("split", split)
	L.Push(node)
	return 1
}

// jsonEncode is squish.json.encode(v): v as JSON, or nil and why not.
func jsonEncode(L *glua.LState) int {
	b, err := toJSON(L.Get(1))
	if err != nil {
		return pushError(L, err.Error(), 0)
	}
	L.Push(glua.LString(b))
	return 1
}

// jsonDecode is squish.json.decode(s): the value s holds, or nil and
// why not.
func jsonDecode(L *glua.LState) int {
	v, err := fromJSON(L, []byte(L.CheckString(1)))
	if err != nil {
		return pushError(L, err.Error(), 0)
	}
	L.Push(v)
	return 1
}
