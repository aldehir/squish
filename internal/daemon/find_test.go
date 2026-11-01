package daemon

import (
	"context"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/aldehir/squish/internal/rpc"
)

// findTree makes the picker's fixture: files and directories, a
// dot-directory, and a node_modules, and returns its root.
func findTree(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, f := range []string{
		"internal/vt/frame.zig",
		"internal/vt/frame_test.zig",
		"internal/vt/frames/.keep",
		"internal/rpc/frame.go",
		"README.md",
		"a b/c.txt",
		".git/HEAD",
		"node_modules/pkg/index.js",
		"zig-out/bin/squish.exe",
	} {
		p := filepath.Join(dir, filepath.FromSlash(f))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(f), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// fileURL is dir as a shell's OSC 7 reports it.
func fileURL(dir string) string {
	p := filepath.ToSlash(dir)
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return (&url.URL{Scheme: "file", Path: p}).String()
}

// findPane is a pane whose shell reports dir, and a client to ask it.
func findPane(t *testing.T, dir string) (PaneID, *Client) {
	t.Helper()
	pane, c, _ := findPaneOn(t, dir)
	return pane, c
}

func findPaneOn(t *testing.T, dir string) (PaneID, *Client, *harness) {
	t.Helper()
	h := newHarness(t)
	w := h.window()
	pane := w.newWorkspace()
	c := h.connect()
	h.pty(0).emit("\x1b]7;" + fileURL(dir) + "\x07")
	eventually(t, "the pwd", func() bool {
		var res rpc.PaneFindResult
		return c.Call(rpc.PaneFind, rpc.PaneFindParams{ID: pane}, &res) == nil && res.Reason == ""
	})
	return pane, c, h
}

// findDone asks until the scan is over.
func findDone(t *testing.T, c *Client, p rpc.PaneFindParams) rpc.PaneFindResult {
	t.Helper()
	var res rpc.PaneFindResult
	eventually(t, "the scan", func() bool {
		if err := c.Call(rpc.PaneFind, p, &res); err != nil {
			t.Fatal(err)
		}
		return !res.Scanning
	})
	return res
}

func paths(items []rpc.FindItem) []string {
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.Path
	}
	return out
}

func TestFindRanksPathFragments(t *testing.T) {
	dir := findTree(t)
	pane, c := findPane(t, dir)
	res := findDone(t, c, rpc.PaneFindParams{ID: pane, Query: "int/vt/fr"})
	if res.Root != dir || res.Pretty == "" || res.Tool == "" {
		t.Fatalf("root %q pretty %q tool %q", res.Root, res.Pretty, res.Tool)
	}
	// The directory and the file score the same; the shorter path comes
	// first, as fzf's length tiebreak has it, and the file after.
	got := paths(res.Items)
	if len(got) < 2 || got[0] != "internal/vt/frames" || got[1] != "internal/vt/frame.zig" {
		t.Fatalf("ranked %v", got)
	}
	if res.Matched != len(got) || res.Total < 5 {
		t.Fatalf("matched %d of %d, %d items", res.Matched, res.Total, len(got))
	}
	file := res.Items[1]
	if !slices.Equal(file.Pos, []int{0, 1, 2, 8, 9, 10, 11, 12, 13}) {
		t.Fatalf("positions %v", file.Pos)
	}
	if file.Insert != "internal/vt/frame.zig" || file.Dir {
		t.Fatalf("insert %q", file.Insert)
	}
	// The directory inserts without a trailing slash.
	if d := res.Items[0]; !d.Dir || d.Insert != "internal/vt/frames" || !slices.Equal(d.Pos, file.Pos) {
		t.Fatalf("the directory: %+v", d)
	}
	// Dot-directories are skipped whichever scanner ran.
	for _, p := range got {
		if strings.HasPrefix(p, ".git") {
			t.Fatalf("listed %q", p)
		}
	}
	// Two terms both have to match.
	res = findDone(t, c, rpc.PaneFindParams{ID: pane, Query: "vt frame"})
	got = paths(res.Items)
	if slices.Contains(got, "internal/rpc/frame.go") || !slices.Contains(got, "internal/vt/frame.zig") {
		t.Fatalf("two terms: %v", got)
	}
	res = findDone(t, c, rpc.PaneFindParams{ID: pane, Query: "zzz"})
	if len(res.Items) != 0 || res.Matched != 0 {
		t.Fatalf("no match: %v", res.Items)
	}
	// Case folds unless the query has a capital (smart case), whatever
	// the query's length: fzf's three-letter path needs its tables.
	for _, q := range []string{"r", "re", "rea", "readme", "README"} {
		res = findDone(t, c, rpc.PaneFindParams{ID: pane, Query: q})
		if !slices.Contains(paths(res.Items), "README.md") {
			t.Fatalf("%q misses README.md: %v", q, paths(res.Items))
		}
	}
	res = findDone(t, c, rpc.PaneFindParams{ID: pane, Query: "Readme"})
	if slices.Contains(paths(res.Items), "README.md") {
		t.Fatalf("a capital in the query still matched README.md")
	}
	// An empty query lists everything, in scan order, up to the limit,
	// each with an empty (not absent) pos.
	res = findDone(t, c, rpc.PaneFindParams{ID: pane, Limit: 2})
	if len(res.Items) != 2 || res.Matched != res.Total || res.Items[0].Pos == nil {
		t.Fatalf("empty query: %d items, %d of %d, pos %v", len(res.Items), res.Matched, res.Total, res.Items[0].Pos)
	}
	// A root above the directory is refused.
	if err := c.Call(rpc.PaneFind, rpc.PaneFindParams{ID: pane, Root: "../x"}, &res); err == nil {
		t.Fatal("root .. was taken")
	}
}

func TestFindWalkerSkips(t *testing.T) {
	dir := findTree(t)
	c := &findCache{root: dir, cancel: func() {}}
	c.walk(context.Background())
	entries, done, truncated := c.snapshot()
	if !done || truncated {
		t.Fatalf("done %v truncated %v", done, truncated)
	}
	var got []string
	for _, e := range entries {
		got = append(got, e.path)
	}
	for _, p := range got {
		for _, skipped := range []string{".git", "node_modules", "zig-out", ".keep"} {
			if strings.Contains(p, skipped) {
				t.Fatalf("listed %q", p)
			}
		}
	}
	for _, want := range []string{"internal", "internal/vt", "internal/vt/frames", "internal/vt/frame.zig", "a b/c.txt", "README.md"} {
		if !slices.Contains(got, want) {
			t.Fatalf("missing %q in %v", want, got)
		}
	}
	for _, e := range entries {
		if e.dir != (e.path == "internal" || e.path == "internal/vt" || e.path == "internal/rpc" || e.path == "internal/vt/frames" || e.path == "a b") {
			t.Fatalf("%q dir %v", e.path, e.dir)
		}
	}
	// The budget ends the walk, and says so.
	small := &findCache{root: dir, cancel: func() {}, budget: 3}
	small.walk(context.Background())
	entries, done, truncated = small.snapshot()
	if !done || !truncated || len(entries) != 3 {
		t.Fatalf("budget: done %v truncated %v, %d entries", done, truncated, len(entries))
	}
}

func TestFindInsertQuoting(t *testing.T) {
	for _, tc := range []struct {
		rel     string
		windows bool
		want    string
	}{
		{"internal/vt/frame.zig", false, "internal/vt/frame.zig"},
		{"a b/c.txt", false, "'a b/c.txt'"},
		{"a b/c.txt", true, "'a b/c.txt'"},
		{"it's", false, `'it'\''s'`},
		{"it's", true, "'it''s'"},
		{"semi;colon", false, "'semi;colon'"},
		{"café", true, "'café'"},
	} {
		if got := findQuote(tc.rel, tc.windows); got != tc.want {
			t.Errorf("findQuote(%q, %v) = %q, want %q", tc.rel, tc.windows, got, tc.want)
		}
	}
	dir := findTree(t)
	pane, c := findPane(t, dir)
	res := findDone(t, c, rpc.PaneFindParams{ID: pane, Query: "c.txt"})
	if len(res.Items) == 0 || res.Items[0].Insert != "'a b/c.txt'" {
		t.Fatalf("quoted insert: %v", res.Items)
	}
}

func TestFindNoPwd(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	pane := w.newWorkspace()
	c := h.connect()
	var res rpc.PaneFindResult
	if err := c.Call(rpc.PaneFind, rpc.PaneFindParams{ID: pane, Query: "x"}, &res); err != nil {
		t.Fatal(err)
	}
	if res.Reason != "no-pwd" || res.Root != "" || len(res.Items) != 0 {
		t.Fatalf("no hook: %+v", res)
	}
	h.pty(0).emit("\x1b]7;file://elsewhere/home/alde\x07")
	eventually(t, "the other host's pwd", func() bool {
		return c.Call(rpc.PaneFind, rpc.PaneFindParams{ID: pane}, &res) == nil && res.Reason == "other-host"
	})
	gone := filepath.Join(t.TempDir(), "gone")
	h.pty(0).emit("\x1b]7;" + fileURL(gone) + "\x07")
	eventually(t, "the gone pwd", func() bool {
		return c.Call(rpc.PaneFind, rpc.PaneFindParams{ID: pane}, &res) == nil && res.Reason == "gone"
	})
	if err := c.Call(rpc.PaneFind, rpc.PaneFindParams{ID: PaneID{WS: 9, Tab: 9, N: 9}}, &res); err == nil {
		t.Fatal("an unknown pane answered")
	}
}

func TestFindCacheSharesScan(t *testing.T) {
	dir := findTree(t)
	pane, c, h := findPaneOn(t, dir)
	srv := h.srv
	// Two clients ask at once: one scan serves both.
	var wg sync.WaitGroup
	for range 2 {
		c := h.connect()
		wg.Add(1)
		go func() {
			defer wg.Done()
			findDone(t, c, rpc.PaneFindParams{ID: pane, Query: "frame"})
		}()
	}
	wg.Wait()
	srv.findMu.Lock()
	n := len(srv.finds)
	srv.findMu.Unlock()
	if n != 1 {
		t.Fatalf("%d caches for one directory", n)
	}
	whole := findDone(t, c, rpc.PaneFindParams{ID: pane})
	// A root under it filters the same scan: paths relative to the root,
	// inserts relative to the directory, the total unchanged.
	under := findDone(t, c, rpc.PaneFindParams{ID: pane, Root: "internal/", Query: "fr"})
	if under.Root != filepath.Join(dir, "internal") || under.Total != whole.Total {
		t.Fatalf("root %q total %d (whole %d)", under.Root, under.Total, whole.Total)
	}
	got := paths(under.Items)
	if !slices.Contains(got, "vt/frame.zig") || slices.Contains(got, "README.md") {
		t.Fatalf("under internal: %v", got)
	}
	i := slices.Index(got, "vt/frame.zig")
	if under.Items[i].Insert != "internal/vt/frame.zig" {
		t.Fatalf("insert %q", under.Items[i].Insert)
	}
	srv.findMu.Lock()
	n = len(srv.finds)
	srv.findMu.Unlock()
	if n != 1 {
		t.Fatalf("%d caches after narrowing", n)
	}
	// A refresh scans again (once: every call with it would start over).
	var fresh rpc.PaneFindResult
	if err := c.Call(rpc.PaneFind, rpc.PaneFindParams{ID: pane, Refresh: true}, &fresh); err != nil {
		t.Fatal(err)
	}
	refreshed := findDone(t, c, rpc.PaneFindParams{ID: pane})
	if refreshed.Total != whole.Total {
		t.Fatalf("refresh: %d of %d", refreshed.Total, whole.Total)
	}
}
