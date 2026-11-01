-- tmux's key bindings as squish chords: ctrl+b, then a key.
--
-- Copy this beside init.lua and dofile("tmux.lua") from it, or make it
-- init.lua. Binding ctrl+b>... hides ctrl+b from the program; ctrl+b
-- ctrl+b sends it, as tmux's send-prefix does. Escape, or a key not in
-- the sequence, ends it. Only what squish has an action or a method for
-- is here: nothing needs a prompt (rename), a chooser (w, s), or copy
-- mode ([). Lua functions bound to a key run in the daemon for the
-- focused pane, so squish.tab and squish.workspace act on its tab and
-- workspace.

local prefix = "ctrl+b"

local function chord(key) return prefix .. ">" .. key end

-- Windows are tabs.
squish.bind(chord("c"), "new_tab")
squish.bind(chord("n"), "next_tab")
squish.bind(chord("p"), "previous_tab")
squish.bind(chord("shift+7"), function() assert(squish.tab.close{}) end) -- & kill-window

-- 0-9 select the window by number, from 0 as tmux's base-index does.
for n = 0, 9 do
  squish.bind(chord(tostring(n)), function()
    local ws = assert(squish.workspace.info{})
    local tab = ws.tabs[n + 1]
    if tab then assert(squish.workspace.focus{ tab = tab.id }) end
  end)
end

-- l goes to the last window: a hook remembers each workspace's previous
-- tab as the selection moves.
local last, current = {}, {}
squish.on("tab.selected", function(ctx, ev)
  local id = squish.id.parse(ev.id)
  if current[id.workspace] ~= ev.id then
    last[id.workspace] = current[id.workspace]
    current[id.workspace] = ev.id
  end
end)
squish.bind(chord("l"), function(ctx)
  local tab = last[ctx.workspace_id]
  if tab then assert(squish.workspace.focus{ tab = tab }) end
end)

-- Panes are splits. tmux's % is a pane to the right and " one below.
squish.bind(chord("shift+5"), "new_split", { direction = "right" })
squish.bind(chord("shift+apostrophe"), "new_split", { direction = "down" })
squish.bind(chord("x"), "close_surface")
squish.bind(chord("shift+1"), function() assert(squish.pane.move{}) end) -- ! break-pane into a tab of its own
squish.bind(chord("z"), "toggle_split_zoom")
squish.bind(chord("shift+e"), "equalize_splits")

squish.bind(chord("o"), "goto_split", { direction = "next" })
squish.bind(chord("semicolon"), "goto_split", { direction = "previous" })
for _, dir in ipairs({ "up", "down", "left", "right" }) do
  squish.bind(chord(dir), "goto_split", { direction = dir })
  squish.bind(chord("ctrl+" .. dir), "resize_split", { direction = dir, amount = 1 })
  squish.bind(chord("alt+" .. dir), "resize_split", { direction = dir, amount = 5 })
end

-- ] pastes; there is no paste buffer, so the clipboard is it.
squish.bind(chord("bracketright"), "paste_from_clipboard")

-- d detaches: the windows showing the workspace drop it and it runs on.
squish.bind(chord("d"), function() assert(squish.workspace.detach{}) end)

-- ctrl+b ctrl+b sends ctrl+b (0x02) to the program.
squish.bind(chord(prefix), function() assert(squish.pane.write{ text = "\2" }) end)
