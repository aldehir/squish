package vt

import (
	"encoding/binary"
	"fmt"
	"strings"
	"testing"
)

// Copy mode (copymode.zig), driven by events as the window sends them.
// The positions are tmux's, as tmux 3.5a gave them on the same text, but
// that the cursor stops on a row's last character, as tmux 3.7's vi keys
// have it.

const frameCopyMode = 1 << 5

// copyModeExit, Enter, Toggle: event.zig's CopyMode.
const (
	copyModeExit   = 0
	copyModeEnter  = 1
	copyModeToggle = 2
)

func evCopyMode(how byte) []byte { return []byte{13, how} }

// evKeyFull is a key press with an identity: key is libghostty-vt's
// number for it (KeyCode), mods its modifiers (bit 0 shift, 1 ctrl),
// unshifted the codepoint of the key without shift, and text what it
// typed.
func evKeyFull(key uint16, mods uint16, unshifted rune, text string) []byte {
	b := []byte{1, 1}
	b = binary.LittleEndian.AppendUint16(b, key)
	b = binary.LittleEndian.AppendUint16(b, mods)
	b = binary.LittleEndian.AppendUint16(b, 0)
	b = append(b, 0)
	b = binary.LittleEndian.AppendUint32(b, uint32(unshifted))
	b = append(b, byte(len(text)))
	b = append(b, text...)
	return append(b, 0)
}

// evCtrl is ctrl and a letter.
func evCtrl(c rune) []byte {
	return evKeyFull(KeyCode("key_"+string(c)), 1<<1, c, string(rune(c-'a'+1)))
}

// frameCursor reads a frame's flags and cursor (frame.zig's header).
func frameCursor(f []byte) (flags byte, x, y uint16, visible bool) {
	flags = f[0]
	i := 1 + 2 + 2 + 1 + 3 + 3 + 1 + 3
	if flags&framePalette != 0 {
		i += 256 * 3
	}
	bits := f[i]
	visible = bits&1 != 0 && bits&(1<<3) != 0
	x = binary.LittleEndian.Uint16(f[i+2:])
	y = binary.LittleEndian.Uint16(f[i+4:])
	return
}

// keys sends each string as a key that typed it.
func keys(t testing.TB, v *View, term *Terminal, texts ...string) (last Result) {
	t.Helper()
	for _, s := range texts {
		last = event(t, v, term, false, evKey(s))
	}
	return last
}

func cursorAt(t testing.TB, v *View, term *Terminal) string {
	t.Helper()
	flags, x, y, _ := frameCursor(frame(t, v, term, false))
	if flags&frameCopyMode == 0 {
		return "not in copy mode"
	}
	return fmt.Sprintf("%d,%d", x, y)
}

func wantCursor(t testing.TB, v *View, term *Terminal, x, y uint16) {
	t.Helper()
	flags, gx, gy, visible := frameCursor(frame(t, v, term, false))
	if flags&frameCopyMode == 0 {
		t.Errorf("frame flags %#x: not in copy mode", flags)
	}
	if !visible || gx != x || gy != y {
		t.Errorf("cursor at %d,%d (visible %v), want %d,%d", gx, gy, visible, x, y)
	}
}

// walk sends each key and gives where the cursor went after each.
func walk(t testing.TB, v *View, term *Terminal, ks ...string) string {
	t.Helper()
	var at []string
	for _, k := range ks {
		keys(t, v, term, k)
		at = append(at, cursorAt(t, v, term))
	}
	return strings.Join(at, " ")
}

func repeat(k string, n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = k
	}
	return out
}

// copyRow copies the row under the cursor, by keys, and leaves copy
// mode with it.
func copyRow(t testing.TB, v *View, term *Terminal) string {
	t.Helper()
	keys(t, v, term, "0", " ", "$")
	r := event(t, v, term, false, evKeyFull(KeyCode("enter"), 0, 0, "\r"))
	return string(r.Text)
}

// TestCopyMode: entering puts the cursor where the program's is, keys
// move it instead of going to the child, Space and Enter select and
// copy, and the mode ends with the copy.
func TestCopyMode(t *testing.T) {
	term := newTerm(t, 20, 4)
	write(t, term, "hello world\r\nsecond line\r\nthird")
	v := newView(t, term)
	event(t, v, term, false, evGeometry(20, 4))
	frame(t, v, term, true)

	if r := event(t, v, term, false, evCopyMode(copyModeEnter)); !r.Changed {
		t.Fatal("entering copy mode changed nothing")
	}
	wantCursor(t, v, term, 5, 2)

	if r := keys(t, v, term, "k"); len(r.Pty) != 0 || !r.Changed {
		t.Errorf("k in copy mode: pty %q, changed %v", r.Pty, r.Changed)
	}
	wantCursor(t, v, term, 5, 1)
	keys(t, v, term, "b")
	wantCursor(t, v, term, 0, 1)
	keys(t, v, term, " ", "e")
	wantCursor(t, v, term, 5, 1)
	r := event(t, v, term, false, evKeyFull(KeyCode("enter"), 0, 0, "\r"))
	if !r.Copied || r.CopyTag != 0 || string(r.Text) != "second" {
		t.Errorf("Enter copied %v tag %d %q, want second", r.Copied, r.CopyTag, r.Text)
	}
	if flags, _, _, _ := frameCursor(frame(t, v, term, false)); flags&frameCopyMode != 0 {
		t.Error("still in copy mode after Enter")
	}
	if r := keys(t, v, term, "x"); string(r.Pty) != "x" {
		t.Errorf("after copy mode, x sent %q", r.Pty)
	}

	// Text events are keys too: "0 ll" and a return typed as text copy
	// "hel".
	event(t, v, term, false, evCopyMode(copyModeEnter))
	keys(t, v, term, "g")
	if r := event(t, v, term, false, evText(2, "0 ll\r")); !r.Copied || string(r.Text) != "hel" || len(r.Pty) != 0 {
		t.Errorf("text in copy mode: copied %v %q, pty %q", r.Copied, r.Text, r.Pty)
	}
	if r := event(t, v, term, false, evCopy(3)); len(r.Text) != 0 {
		t.Errorf("a selection %q survived leaving copy mode", r.Text)
	}
}

// TestCopyModeSnapshot: copy mode shows the pane as it was when it
// started, while the program's output goes on into the terminal unseen;
// leaving shows it. A copy takes the snapshot's selection.
func TestCopyModeSnapshot(t *testing.T) {
	term := newTerm(t, 20, 4)
	write(t, term, "before\r\n")
	v := newView(t, term)
	event(t, v, term, false, evGeometry(20, 4))
	frame(t, v, term, true)
	event(t, v, term, false, evCopyMode(copyModeEnter))
	wantCursor(t, v, term, 0, 1)

	write(t, term, "AFTER\r\nmore\r\nand more\r\nand more")
	text, _ := FrameText(frame(t, v, term, true))
	if strings.Contains(text, "AFTER") || !strings.HasPrefix(text, "before\n") {
		t.Errorf("copy mode shows %q, want the snapshot", text)
	}
	wantCursor(t, v, term, 0, 1)
	keys(t, v, term, "k", " ", "$")
	if r := event(t, v, term, false, evCopy(4)); string(r.Text) != "before" {
		t.Errorf("a copy in copy mode took %q, want before", r.Text)
	}

	keys(t, v, term, "q")
	text, _ = FrameText(frame(t, v, term, true))
	if !strings.Contains(text, "AFTER") {
		t.Errorf("after q the pane shows %q, want the output", text)
	}
}

// TestCopyModeResize: the snapshot reflows with the pane, and the
// cursor stays on its character.
func TestCopyModeResize(t *testing.T) {
	term := newTerm(t, 20, 4)
	write(t, term, "abcdefghij klmnop")
	v := newView(t, term)
	event(t, v, term, false, evGeometry(20, 4))
	frame(t, v, term, true)
	event(t, v, term, false, evCopyMode(copyModeEnter))
	keys(t, v, term, "0", "w")
	wantCursor(t, v, term, 11, 0)

	if err := term.Resize(10, 4, 10, 20); err != nil {
		t.Fatal(err)
	}
	f := frame(t, v, term, true)
	if cols := binary.LittleEndian.Uint16(f[1:]); cols != 10 {
		t.Errorf("after the resize the frame is %d wide, want 10", cols)
	}
	wantCursor(t, v, term, 1, 1)
	keys(t, v, term, " ", "e")
	if r := event(t, v, term, false, evKeyFull(KeyCode("enter"), 0, 0, "\r")); string(r.Text) != "klmnop" {
		t.Errorf("after the resize the cursor's word is %q, want klmnop", r.Text)
	}
}

const wordsRow = "foo.bar baz-qux  hello_world (a [b {c} d] e) end"

func wordsPane(t *testing.T) (*Terminal, *View) {
	term := newTerm(t, 60, 6)
	write(t, term, wordsRow+"\r\nGhostTY ghostty Ghostty ghosts gh xx")
	v := newView(t, term)
	event(t, v, term, false, evGeometry(60, 6))
	frame(t, v, term, true)
	event(t, v, term, false, evCopyMode(copyModeEnter))
	keys(t, v, term, "g")
	return term, v
}

// TestCopyModeWords: w, e, b and W, E, B as tmux has them, punctuation
// runs words of their own (word-separators), on into the next line.
func TestCopyModeWords(t *testing.T) {
	term, v := wordsPane(t)
	for _, c := range []struct {
		start string
		keys  []string
		want  string
	}{
		{"0", repeat("w", 19), "3,0 4,0 8,0 11,0 12,0 17,0 29,0 30,0 32,0 33,0 35,0 36,0 37,0 39,0 40,0 42,0 43,0 45,0 0,1"},
		{"0", repeat("e", 17), "2,0 3,0 6,0 10,0 11,0 14,0 27,0 29,0 30,0 32,0 33,0 35,0 36,0 37,0 39,0 40,0 42,0"},
		{"$", repeat("b", 16), "45,0 43,0 42,0 40,0 39,0 37,0 36,0 35,0 33,0 32,0 30,0 29,0 17,0 12,0 11,0 8,0"},
		{"0", repeat("W", 9), "8,0 17,0 29,0 32,0 35,0 39,0 42,0 45,0 0,1"},
		{"0", repeat("E", 9), "6,0 14,0 27,0 30,0 33,0 37,0 40,0 43,0 47,0"},
		{"$", repeat("B", 9), "45,0 42,0 39,0 35,0 32,0 29,0 17,0 8,0 0,0"},
	} {
		keys(t, v, term, "g", c.start)
		if got := walk(t, v, term, c.keys...); got != c.want {
			t.Errorf("%s then %s: %s\nwant %s", c.start, c.keys[0], got, c.want)
		}
	}
	// $ stops on the last character, as tmux's vi keys do.
	keys(t, v, term, "g", "$")
	wantCursor(t, v, term, 47, 0)
}

// TestCopyModeJumps: f, t, F, T with counts, ; and , (; after t goes on
// past the target it stopped at), and %.
func TestCopyModeJumps(t *testing.T) {
	term, v := wordsPane(t)
	for _, c := range []struct {
		name string
		keys []string
		want string
	}{
		{"fa ; ; ,", []string{"0", "f", "a", ";", ";", ","}, "9,0"},
		{"fa", []string{"0", "f", "a"}, "5,0"},
		{"fa ; ;", []string{"0", "f", "a", ";", ";"}, "30,0"},
		{"ta", []string{"0", "t", "a"}, "4,0"},
		{"ta ;", []string{"0", "t", "a", ";"}, "8,0"},
		{"$ Fb", []string{"$", "F", "b"}, "33,0"},
		{"$ Fb Tz", []string{"$", "F", "b", "T", "z"}, "11,0"},
		{"2fb", []string{"0", "2", "f", "b"}, "8,0"},
		{"fq, absent from the line after", []string{"j", "0", "f", "q"}, "0,1"},
		{"% on (", []string{"0", "2", "9", "l", "%"}, "43,0"},
		{"% on ( and back", []string{"0", "2", "9", "l", "%", "%"}, "29,0"},
		{"% off a bracket", []string{"0", "%"}, "43,0"},
		{"% on }", []string{"0", "3", "7", "l", "%"}, "35,0"},
	} {
		keys(t, v, term, "g")
		keys(t, v, term, c.keys...)
		if got := cursorAt(t, v, term); got != c.want {
			t.Errorf("%s: cursor at %s, want %s", c.name, got, c.want)
		}
	}
}

// TestCopyModeLines: 0, ^, $ and w take a wrapped line as one; { and }
// stop at blank lines.
func TestCopyModeLines(t *testing.T) {
	term := newTerm(t, 20, 8)
	write(t, term, "wrapped:w01 w02 w03 w04 w05\r\n    indented\r\n\r\nc\r\nd\r\n\r\ne")
	v := newView(t, term)
	event(t, v, term, false, evGeometry(20, 8))
	frame(t, v, term, true)
	event(t, v, term, false, evCopyMode(copyModeEnter))

	for _, c := range []struct {
		name string
		keys []string
		want string
	}{
		{"$ to the wrapped line's end", []string{"g", "$"}, "6,1"},
		{"0 from its second row", []string{"g", "j", "l", "l", "0"}, "0,0"},
		{"^ past the indent", []string{"g", "j", "j", "$", "^"}, "4,2"},
		{"w over the wrap", []string{"g", "1", "6", "l", "w"}, "0,1"},
	} {
		keys(t, v, term, c.keys...)
		if got := cursorAt(t, v, term); got != c.want {
			t.Errorf("%s: cursor at %s, want %s", c.name, got, c.want)
		}
	}
	keys(t, v, term, "G")
	if got, want := walk(t, v, term, "{", "{", "{", "{", "}", "}", "}", "}"), "0,6 0,3 0,0 0,0 0,3 0,6 0,7 0,7"; got != want {
		t.Errorf("{ and }: %s\nwant %s", got, want)
	}
}

func historyPane(t *testing.T, rows uint16) (*Terminal, *View) {
	term := newTerm(t, 20, rows)
	for i := range 30 {
		write(t, term, "line "+string(rune('a'+i))+"\r\n")
	}
	v := newView(t, term)
	event(t, v, term, false, evGeometry(20, uint32(rows)))
	frame(t, v, term, true)
	event(t, v, term, false, evCopyMode(copyModeEnter))
	return term, v
}

func topRow(t testing.TB, v *View, term *Terminal) string {
	t.Helper()
	text, _ := FrameText(frame(t, v, term, true))
	row, _, _ := strings.Cut(text, "\n")
	return row
}

// TestCopyModeScreen: H, M, L to column 0; g and G; pages two rows
// short of the view and half pages, the cursor keeping its row; z.
func TestCopyModeScreen(t *testing.T) {
	term, v := historyPane(t, 6)
	keys(t, v, term, "l")
	if got, want := walk(t, v, term, "H", "M", "L"), "0,0 0,2 0,5"; got != want {
		t.Errorf("H M L: %s, want %s", got, want)
	}
	keys(t, v, term, "g")
	wantCursor(t, v, term, 0, 0)
	if top := topRow(t, v, term); top != "line a" {
		t.Errorf("g shows %q at the top", top)
	}
	keys(t, v, term, "G")
	wantCursor(t, v, term, 0, 5)

	for _, c := range []struct {
		key rune
		top string
	}{{'u', "line w"}, {'b', "line s"}, {'f', "line w"}, {'d', "line z"}, {'d', "line z"}} {
		event(t, v, term, false, evCtrl(c.key))
		if top := topRow(t, v, term); top != c.top {
			t.Errorf("ctrl+%c: top row %q, want %q", c.key, top, c.top)
		}
		wantCursor(t, v, term, 0, 5)
	}

	keys(t, v, term, "G", "5", "k", "z")
	wantCursor(t, v, term, 0, 2)
	if top := topRow(t, v, term); top != "line x" {
		t.Errorf("z: top row %q, want line x", top)
	}
}

// TestCopyModeLinesAndCounts: g goes to the top of history, V selects
// lines, a count repeats a motion, Enter copies and leaves, and Escape
// clears the selection but stays.
func TestCopyModeLinesAndCounts(t *testing.T) {
	term := newTerm(t, 20, 6)
	write(t, term, "one\r\ntwo\r\nthree\r\nfour\r\nfive")
	v := newView(t, term)
	event(t, v, term, false, evGeometry(20, 6))
	frame(t, v, term, true)
	event(t, v, term, false, evCopyMode(copyModeToggle))
	wantCursor(t, v, term, 4, 4)

	keys(t, v, term, "g")
	wantCursor(t, v, term, 0, 0)
	keys(t, v, term, "V", "2", "j")
	wantCursor(t, v, term, 0, 2)
	escape := evKeyFull(KeyCode("escape"), 0, 0, "\x1b")
	if r := event(t, v, term, false, escape); !r.Changed {
		t.Error("escape changed nothing")
	}
	if r := event(t, v, term, false, evCopy(5)); len(r.Text) != 0 {
		t.Errorf("escape left %q selected", r.Text)
	}
	if flags, _, _, _ := frameCursor(frame(t, v, term, false)); flags&frameCopyMode == 0 {
		t.Error("escape left copy mode")
	}
	keys(t, v, term, "V", "k")
	r := event(t, v, term, false, evKeyFull(KeyCode("enter"), 0, 0, "\r"))
	if !r.Copied || string(r.Text) != "two\nthree" {
		t.Errorf("enter copied %v %q, want two and three", r.Copied, r.Text)
	}
}

// TestCopyModeRectangle: v (or ctrl+v) makes the selection a block.
func TestCopyModeRectangle(t *testing.T) {
	term := newTerm(t, 20, 4)
	write(t, term, "hello world\r\nsecond line")
	v := newView(t, term)
	event(t, v, term, false, evGeometry(20, 4))
	frame(t, v, term, true)
	for _, toggle := range [][]byte{evKey("v"), evCtrl('v')} {
		event(t, v, term, false, evCopyMode(copyModeEnter))
		keys(t, v, term, "g")
		event(t, v, term, false, toggle)
		keys(t, v, term, " ", "2", "l", "j")
		r := event(t, v, term, false, evKeyFull(KeyCode("enter"), 0, 0, "\r"))
		if !r.Copied || string(r.Text) != "hel\nsec" {
			t.Errorf("block copied %v %q, want hel and sec", r.Copied, r.Text)
		}
	}
}

// TestCopyModeKeys: the table from the config replaces and removes
// defaults, by our names or tmux's, reports a line that doesn't parse,
// and an empty table is tmux's defaults again.
func TestCopyModeKeys(t *testing.T) {
	term := newTerm(t, 20, 4)
	write(t, term, "hello world")
	src := newSource(t)
	v := newViewOf(t, src, term)
	event(t, v, term, false, evGeometry(20, 4))
	frame(t, v, term, true)

	bad, err := src.SetCopyKeys("x\tcancel\nv\tbegin-selection\ny\tcopy-pipe-and-cancel\nnope\tcancel\nq\tnot_a_thing\n")
	if err != nil {
		t.Fatal(err)
	}
	if bad != "nope\tcancel" {
		t.Errorf("bad line %q, want the one with the unknown key", bad)
	}
	event(t, v, term, false, evCopyMode(copyModeEnter))
	keys(t, v, term, "0", "v", "l", "l")
	if !src.CopyMode() {
		t.Fatal("not in copy mode")
	}
	keys(t, v, term, "x")
	if src.CopyMode() {
		t.Error("x, bound to cancel, didn't leave copy mode")
	}
	event(t, v, term, false, evCopyMode(copyModeEnter))
	if r := keys(t, v, term, "0", "v", "l", "l", "y"); !r.Copied || string(r.Text) != "hel" {
		t.Errorf("v l l y copied %v %q, want hel", r.Copied, r.Text)
	}
	if src.CopyMode() {
		t.Error("y didn't leave copy mode")
	}

	// tmux's defaults: v toggles a rectangle and selects nothing, y is
	// unbound, and Enter with nothing selected copies nothing but still
	// leaves, as tmux's copy-pipe-and-cancel does.
	if _, err := src.SetCopyKeys(""); err != nil {
		t.Fatal(err)
	}
	event(t, v, term, false, evCopyMode(copyModeEnter))
	keys(t, v, term, "0", "v", "l", "l", "y")
	if r := event(t, v, term, false, evKeyFull(KeyCode("enter"), 0, 0, "\r")); r.Copied {
		t.Errorf("with the defaults back, v selected: copied %q", r.Text)
	}
	if src.CopyMode() {
		t.Error("Enter didn't leave copy mode")
	}
}

// TestCopyModeMouse: a drag while in copy mode sets the selection and
// puts the cursor at its end, which the keys go on from; a click moves
// the cursor; the program hears nothing of the mouse.
func TestCopyModeMouse(t *testing.T) {
	term := newTerm(t, 20, 4)
	write(t, term, "hello world\r\nsecond")
	v := newView(t, term)
	event(t, v, term, false, evGeometry(20, 4))
	frame(t, v, term, true)
	event(t, v, term, false, evCopyMode(copyModeEnter))

	// Cells are 10x20: a drag from cell 0 into the right half of cell 4
	// on the first row selects "hello" (TestEventSelect).
	event(t, v, term, false, evMouse(mousePress, buttonLeft, true, 1, 1, 1000))
	event(t, v, term, false, evMouse(mouseMotion, 0, true, 48, 1, 1010))
	event(t, v, term, false, evMouse(mouseRelease, buttonLeft, false, 48, 1, 1020))
	wantCursor(t, v, term, 4, 0)
	keys(t, v, term, "l", "l")
	if r := event(t, v, term, false, evKeyFull(KeyCode("enter"), 0, 0, "\r")); !r.Copied || string(r.Text) != "hello w" {
		t.Errorf("drag then l l Enter copied %v %q", r.Copied, r.Text)
	}

	event(t, v, term, false, evCopyMode(copyModeEnter))
	event(t, v, term, false, evMouse(mousePress, buttonLeft, true, 25, 25, 5000))
	event(t, v, term, false, evMouse(mouseRelease, buttonLeft, false, 25, 25, 5010))
	wantCursor(t, v, term, 2, 1)
	// A program asking for mouse reports gets none in copy mode.
	write(t, term, "\x1b[?1000h")
	if r := event(t, v, term, false, evMouse(mousePress, buttonLeft, true, 25, 25, 6000)); len(r.Pty) != 0 {
		t.Errorf("click in copy mode reported %q", r.Pty)
	}
	event(t, v, term, false, evMouse(mouseRelease, buttonLeft, false, 25, 25, 6010))
	event(t, v, term, false, evCopyMode(copyModeExit))
	if r := event(t, v, term, false, evMouse(mousePress, buttonLeft, true, 25, 25, 7000)); len(r.Pty) == 0 {
		t.Error("out of copy mode, a click wasn't reported")
	}
}

// TestCopyModeScrollUp: scrolling the viewport up from under a cursor on
// the bottom row (K, or the wheel) keeps the cursor in view, on the new
// bottom row.
func TestCopyModeScrollUp(t *testing.T) {
	term, v := historyPane(t, 4)
	wantCursor(t, v, term, 0, 3)

	keys(t, v, term, "K")
	wantCursor(t, v, term, 0, 3)
	if got := copyRow(t, v, term); got != "line ~" {
		t.Errorf("after K, the row under the cursor is %q, want line ~", got)
	}

	event(t, v, term, false, evCopyMode(copyModeEnter))
	event(t, v, term, false, evWheel(240, 1))
	wantCursor(t, v, term, 0, 3)
	if got := copyRow(t, v, term); got != "line }" {
		t.Errorf("after two wheel notches, the row under the cursor is %q, want line }", got)
	}

	// Away from the edge, the cursor stays on its text as the view
	// moves under it.
	event(t, v, term, false, evCopyMode(copyModeEnter))
	keys(t, v, term, "k", "k")
	wantCursor(t, v, term, 0, 1)
	keys(t, v, term, "K")
	wantCursor(t, v, term, 0, 2)
	if got := copyRow(t, v, term); got != "line }" {
		t.Errorf("after k k K, the row under the cursor is %q, want line }", got)
	}
}

// TestCopyModeColumn: a row shorter than the cursor's column puts the
// cursor on its last character, and the next long row has it back at
// the column.
func TestCopyModeColumn(t *testing.T) {
	term := newTerm(t, 30, 4)
	write(t, term, "a long line here\r\nab\r\nanother long line")
	v := newView(t, term)
	event(t, v, term, false, evGeometry(30, 4))
	frame(t, v, term, true)
	event(t, v, term, false, evCopyMode(copyModeEnter))
	keys(t, v, term, "0", "9", "l")
	wantCursor(t, v, term, 9, 2)
	keys(t, v, term, "k")
	wantCursor(t, v, term, 1, 1)
	keys(t, v, term, "k")
	wantCursor(t, v, term, 9, 0)
	keys(t, v, term, "l", "j", "j")
	wantCursor(t, v, term, 10, 2)
}

// TestCopyModeScroll: motions past the viewport scroll it, and leaving
// brings it back to the bottom.
func TestCopyModeScroll(t *testing.T) {
	term, v := historyPane(t, 4)
	wantCursor(t, v, term, 0, 3)
	// The viewport shows lines 27 to 29 (| } ~) and the empty row the
	// cursor is on; five rows up is line 25 (z), which scrolls in at
	// the top.
	keys(t, v, term, "5", "k")
	wantCursor(t, v, term, 0, 0)
	if top := topRow(t, v, term); top != "line z" {
		t.Errorf("viewport top is %q, want line z", top)
	}
	keys(t, v, term, "q")
	if text, _ := FrameText(frame(t, v, term, true)); !strings.HasPrefix(text, "line |\n") {
		t.Errorf("after q the viewport shows %q, want the bottom again", text)
	}
	if flags, _, _, _ := frameCursor(frame(t, v, term, false)); flags&frameCopyMode != 0 {
		t.Error("q didn't leave copy mode")
	}
}

func searchPane(t *testing.T) (*Terminal, *View) {
	term := newTerm(t, 40, 6)
	write(t, term, "GhostTY ghostty Ghostty ghosts gh xx\r\n")
	for i := range 20 {
		write(t, term, fmt.Sprintf("filler %02d\r\n", i))
	}
	write(t, term, "tail one ghostty\r\ntail two\r\n")
	v := newView(t, term)
	event(t, v, term, false, evGeometry(40, 6))
	frame(t, v, term, true)
	event(t, v, term, false, evCopyMode(copyModeEnter))
	return term, v
}

// TestCopyModeSearch: / and ? ask the window for a needle; the search
// runs from the cursor when it comes, ignores case for a lowercase
// needle, wraps, lands on a match's start (a far one a quarter of the
// view up from the bottom), and n and N go on; matches are counted and
// marked, the one under the cursor as current.
func TestCopyModeSearch(t *testing.T) {
	term, v := searchPane(t)
	wantCursor(t, v, term, 0, 5)
	if r := keys(t, v, term, "/"); r.SearchPrompt != 1 || r.Changed {
		t.Errorf("/ asked for %d (changed %v), want 1", r.SearchPrompt, r.Changed)
	}
	if r := keys(t, v, term, "?"); r.SearchPrompt != 2 {
		t.Errorf("? asked for %d, want 2", r.SearchPrompt)
	}
	wantCursor(t, v, term, 0, 5)

	event(t, v, term, false, evSearch(searchDown, "ghostty"))
	wantCursor(t, v, term, 0, 0)
	wantSearch(t, v, term, true, 4, 1)
	rows := frameRows(t, frame(t, v, term, true))
	want := map[highlight]bool{{2, 0, 6}: true, {1, 8, 14}: true, {1, 16, 22}: true}
	if len(rows[0]) != 3 {
		t.Errorf("row 0 marks %v, want %v", rows[0], want)
	}
	for _, h := range rows[0] {
		if !want[h] {
			t.Errorf("row 0 marks %v, want %v", rows[0], want)
		}
	}

	if got, want := walk(t, v, term, "n", "n", "n", "n", "N"), "8,0 16,0 9,5 0,0 9,5"; got != want {
		t.Errorf("n n n n N: %s, want %s", got, want)
	}
	// The far match sits a quarter of the view (a row) up from the
	// bottom.
	if top := topRow(t, v, term); top != "filler 15" {
		t.Errorf("the far match shows %q at the top, want filler 15", top)
	}
	wantSearch(t, v, term, true, 4, 4)

	// A capital: case counts.
	event(t, v, term, false, evSearch(searchDown, "Ghostty"))
	wantCursor(t, v, term, 16, 0)
	wantSearch(t, v, term, true, 1, 1)

	// From inside a match, down goes past it.
	keys(t, v, term, "0", "w")
	keys(t, v, term, "l", "l")
	event(t, v, term, false, evSearch(searchDown, "ghostty"))
	wantCursor(t, v, term, 16, 0)

	// The window's arrows are n and N.
	event(t, v, term, false, evSearchStep(stepNext))
	wantCursor(t, v, term, 9, 5)
	event(t, v, term, false, evSearchStep(stepPrev))
	wantCursor(t, v, term, 16, 0)

	// None: the cursor stays and the marks go.
	event(t, v, term, false, evSearch(searchDown, "zzzz"))
	wantCursor(t, v, term, 16, 0)
	wantSearch(t, v, term, false, 0, 0)
	keys(t, v, term, "n")
	wantCursor(t, v, term, 16, 0)
}

// TestCopyModeSearchWord: * and # search for the word under the cursor,
// a needle like any other: a capital in it makes case count.
func TestCopyModeSearchWord(t *testing.T) {
	term, v := searchPane(t)
	keys(t, v, term, "g", "w")
	wantCursor(t, v, term, 8, 0)
	keys(t, v, term, "*")
	wantCursor(t, v, term, 16, 0)
	wantSearch(t, v, term, true, 4, 3)
	keys(t, v, term, "n", "#")
	wantCursor(t, v, term, 16, 0)
	wantSearch(t, v, term, true, 4, 3)
	keys(t, v, term, "#")
	wantCursor(t, v, term, 16, 0)
	wantSearch(t, v, term, true, 1, 1)
}

// TestCopyModeSearchAgain: the needle outlives the mode, and the next
// one's n searches up for it, as tmux's does; leaving takes the marks.
func TestCopyModeSearchAgain(t *testing.T) {
	term, v := searchPane(t)
	event(t, v, term, false, evSearch(searchDown, "ghostty"))
	keys(t, v, term, "q")
	wantSearch(t, v, term, false, 0, 0)

	event(t, v, term, false, evCopyMode(copyModeEnter))
	wantSearch(t, v, term, false, 0, 0)
	keys(t, v, term, "n")
	wantCursor(t, v, term, 9, 3)
	wantSearch(t, v, term, true, 4, 4)
}
