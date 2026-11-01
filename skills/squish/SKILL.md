---
name: squish
description: >-
  Drive squish, the terminal daemon this shell runs in, from the command
  line: split panes, open tabs and workspaces, type into panes, read their
  screens, move and focus them, run Lua in the daemon. Use when asked to
  arrange, read, or control the terminal, open something beside the current
  pane, watch another pane's output, or script squish. Applies when the
  environment has SQUISH_PANE or SQUISH_EXE.
---

# Driving squish

squish is a daemon that owns terminals. Each pane is a program on a pty
with its terminal state; panes sit in tabs (a layout tree), tabs in
workspaces; windows draw them, locally or over SSH, and panes outlive
their windows. The `squish` command controls all of it, and every control
is also a JSON-RPC method (`squish call`) and a Lua function (`squish do`).

## Find the CLI

A shell in a squish pane has `SQUISH_EXE`, the daemon's own executable, and
its directory is first on `PATH`, so `squish` runs it. If `squish` isn't
found (a shell profile reset `PATH`), run `"$SQUISH_EXE"` (`& $env:SQUISH_EXE`
in PowerShell), or put `$(dirname "$SQUISH_EXE")` back on `PATH`. Use that
executable and not another squish on the machine: it is the build the
daemon runs, so its commands and its manual match the daemon.

No `SQUISH_EXE` means this shell isn't in a squish pane. Then squish can't
be driven from here unless a `squish` on `PATH` reaches a daemon.

## Learn it from the CLI

The CLI is its own manual, for the exact build you're talking to. Run
`squish help` once and read it all: every command with its flags, then the
topics. Afterwards, `squish help <command>` (`squish help pane split`) or
`squish help <topic>`:

- `env`: `SQUISH_PANE`, `SQUISH_WORKSPACE`, `SQUISH_EXE`, `SQUISH_INSTANCE`
- `ids`: workspaces, tabs, and panes are paths (`1`, `1.2`, `1.2.3`)
- `lua`: the `squish` table scripts get, with examples
- `methods`, `events`: the control plane, for `squish call` and scripts

Don't guess flags, methods, or fields: read them from `squish help`.

## The shape of it

- `squish ls` lists every workspace, tab, and pane, with ids; `--json` on
  any command gives the daemon's reply as data.
- Pane commands (`split`, `write`, `text`, `focus`, `move`, `info`,
  `kill`) act on this pane when given none; `squish tab new` adds to this
  workspace; `squish do` runs its script for this pane.
- `squish pane split right <command>` opens a pane beside this one and
  prints its id; `squish pane text <id>` reads its screen and scrollback
  without disturbing it; `squish pane write <id> <text>` types into it,
  where a carriage return presses enter.
- `squish pane split right --browser <url>` opens a browser pane instead:
  the window's browser shows the page, and squish keeps only its url and
  title. `squish pane navigate <id> <url>` sends it elsewhere; `write` and
  `text` are for terminals and fail on it.
- A pane's program ending ends the pane. To keep a result on screen,
  run a shell and write the command to it.
- `squish do <file.lua>` runs Lua in the daemon; `squish do <action>` runs
  an action the user's `init.lua` defined (`squish actions` lists them,
  `squish config show` the rest of the config). Don't edit `init.lua`
  unless asked.
- A script can wait for things instead of polling: `squish.wait("pane.exited",
  { pane_id = id }, 60)` blocks until that pane's program ends, and
  `squish.on` runs a function for each event (`squish help lua`, `squish help
  events`). A script with a live hook keeps running; `squish scripts kill`
  ends it.

## Manners

The user is working in these panes. Don't kill, move, or type into
panes you didn't make unless asked; read them freely. Prefer a new pane
or tab for your own work, and clean up what you opened when done.
