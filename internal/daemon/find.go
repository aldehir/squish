package daemon

import (
	"bufio"
	"context"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	goruntime "runtime"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/junegunn/fzf/src/algo"
	"github.com/junegunn/fzf/src/util"

	"github.com/aldehir/squish/internal/rpc"
)

// pane.find: the window's file picker. The pane's shell reports its
// directory (OSC 7, squish shell-integration); the first call on a
// directory starts a scan of the tree under it, fd's where fd is
// installed (hidden skipped, .gitignore honored) and a walk of our own
// where not, and every call answers from what the scan has so far,
// ranked by fzf's own scorer so the picker feels like fzf without
// needing it. The scan is cached by directory: a keystroke is one
// round trip that matches, never a process; a root under the directory
// (Tab on a directory row) filters the same scan by prefix.

const (
	// findBudget is where a scan stops (the result says truncated).
	findBudget = 200_000
	// findTTL is how long a finished scan answers before the next call
	// scans again, so new files show up.
	findTTL = 60 * time.Second
	// findIdle is how long an unqueried cache is kept.
	findIdle = 5 * time.Minute
	// findDefaultLimit and findMaxLimit bound how many items a reply
	// carries.
	findDefaultLimit = 50
	findMaxLimit     = 200
	// findParallel is how many entries one goroutine ranks before the
	// work is split across the CPUs.
	findParallel = 4096
)

// fzf's scorer reads tables Init fills: without it no character has a
// class, so uppercase text never folds for a query of three letters or
// more (the shorter ones take fast paths of their own). The path scheme
// scores a match after a slash as a word start.
func init() {
	algo.Init("path")
}

// findSkip names the walker skips (fd reads .gitignore; the walk reads
// nothing), on top of anything starting with a dot.
var findSkip = map[string]bool{
	"node_modules": true,
	"zig-out":      true,
	"zig-cache":    true,
	"target":       true,
}

type findEntry struct {
	path string // relative to the cache's root, forward slashes
	dir  bool
}

// findCache is one scan of a directory tree, shared by every query on
// it. The scan runs on its own goroutines; queries read the entries
// under mu while it appends, and only ever a prefix of them, so a
// snapshot stays valid as the slice grows.
type findCache struct {
	root string
	tool string
	// Entries the scan stops at: findBudget, unless a test says less.
	budget int

	mu        sync.Mutex
	entries   []findEntry
	done      bool
	truncated bool
	finished  time.Time
	used      time.Time
	cancel    context.CancelFunc
}

// add keeps an entry; false once the budget is spent, which ends the
// scan.
func (c *findCache) add(rel string, dir bool) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	budget := c.budget
	if budget == 0 {
		budget = findBudget
	}
	if len(c.entries) >= budget {
		c.truncated = true
		return false
	}
	c.entries = append(c.entries, findEntry{path: rel, dir: dir})
	return true
}

func (c *findCache) end() {
	c.mu.Lock()
	c.done = true
	c.finished = time.Now()
	c.mu.Unlock()
}

// snapshot is the entries so far and the scan's state.
func (c *findCache) snapshot() (entries []findEntry, done, truncated bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.entries[:len(c.entries):len(c.entries)], c.done, c.truncated
}

// paneFind answers a query over the pane's shell's directory.
func (s *Server) paneFind(_ *callCtx, p rpc.PaneFindParams) (*rpc.PaneFindResult, error) {
	pn := s.pane(p.ID)
	if pn == nil {
		return nil, errNoPane
	}
	term, ok := pn.(*Pane)
	if !ok {
		return nil, errNotTerminal(pn.paneID())
	}
	root, err := cleanFindRoot(p.Root)
	if err != nil {
		return nil, rpc.Errorf(rpc.CodeInvalidParams, "%v", err)
	}
	limit := p.Limit
	if limit <= 0 {
		limit = findDefaultLimit
	}
	limit = min(limit, findMaxLimit)
	dir, reason := term.findDir()
	if reason != "" {
		return &rpc.PaneFindResult{Reason: reason, Items: []rpc.FindItem{}}, nil
	}
	cache := s.findCacheFor(dir, p.Refresh)
	entries, done, truncated := cache.snapshot()
	searched := dir
	prefix := ""
	if root != "" {
		searched = filepath.Join(dir, filepath.FromSlash(root))
		prefix = root + "/"
	}
	res := &rpc.PaneFindResult{
		Root:      searched,
		Pretty:    prettyPath(searched),
		Items:     []rpc.FindItem{},
		Total:     len(entries),
		Scanning:  !done,
		Truncated: truncated,
		Tool:      cache.tool,
	}
	hits, matched := findRank(entries, prefix, p.Query, limit)
	res.Matched = matched
	windows := goruntime.GOOS == "windows"
	for _, h := range hits {
		e := entries[h.idx]
		rel := e.path[len(prefix):]
		res.Items = append(res.Items, rpc.FindItem{
			Path:   rel,
			Dir:    e.dir,
			Pos:    h.pos,
			Insert: findQuote(e.path, windows),
		})
	}
	return res, nil
}

// findDir is the directory the pane's shell last reported, as a path
// here, or why there's none: no-pwd (it reported none), other-host (it
// reported another host's: a shell on a further ssh hop), or gone (the
// directory, or the shell).
func (p *Pane) findDir() (dir, reason string) {
	p.mu.Lock()
	done := p.done
	var pwd string
	if !done {
		pwd, _ = p.term.Pwd()
	}
	p.mu.Unlock()
	if done {
		return "", "gone"
	}
	pwd = strings.TrimSpace(pwd)
	if pwd == "" {
		return "", "no-pwd"
	}
	dir = pwdPath(pwd, localHost())
	if dir == "" {
		if strings.HasPrefix(pwd, "file://") || strings.HasPrefix(pwd, "kitty-shell-cwd://") {
			return "", "other-host"
		}
		return "", "no-pwd"
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return "", "gone"
	}
	return dir, ""
}

// cleanFindRoot is root as a relative path with forward slashes and no
// trailing slash ("" for the directory itself), or an error if it
// isn't one under the directory.
func cleanFindRoot(root string) (string, error) {
	root = strings.Trim(filepath.ToSlash(root), "/")
	if root == "" {
		return "", nil
	}
	if strings.Contains(root, ":") {
		return "", errors.New("root must be relative to the pane's directory")
	}
	clean := path.Clean(root)
	if clean == "." {
		return "", nil
	}
	if clean == ".." || strings.HasPrefix(clean, "../") {
		return "", errors.New("root must not leave the pane's directory")
	}
	return clean, nil
}

// prettyPath is dir home-relative, with forward slashes, for the chip:
// ~/dev/squish; a directory outside home as the host spells it.
func prettyPath(dir string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return dir
	}
	if dir == home {
		return "~"
	}
	if rest, ok := strings.CutPrefix(dir, home+string(filepath.Separator)); ok {
		return "~/" + filepath.ToSlash(rest)
	}
	return dir
}

// findQuote is rel as the shell takes it: as is when it's only
// [A-Za-z0-9._/-], else in single quotes, which PowerShell doubles an
// inner one in and POSIX shells close and reopen around.
func findQuote(rel string, windows bool) string {
	plain := true
	for _, r := range rel {
		if r < 0x80 && (unicode.IsLetter(r) || unicode.IsDigit(r)) {
			continue
		}
		switch r {
		case '.', '_', '/', '-':
			continue
		}
		plain = false
		break
	}
	if plain {
		return rel
	}
	if windows {
		return "'" + strings.ReplaceAll(rel, "'", "''") + "'"
	}
	return "'" + strings.ReplaceAll(rel, "'", `'\''`) + "'"
}

// findCacheFor is the scan of dir: the one running or recently
// finished, or a new one (always with refresh).
func (s *Server) findCacheFor(dir string, refresh bool) *findCache {
	s.findMu.Lock()
	defer s.findMu.Unlock()
	now := time.Now()
	s.sweepFindsLocked(now)
	c := s.finds[dir]
	if c != nil {
		c.mu.Lock()
		stale := refresh || (c.done && now.Sub(c.finished) > findTTL)
		c.mu.Unlock()
		if stale {
			c.cancel()
			delete(s.finds, dir)
			c = nil
		}
	}
	if c == nil {
		c = s.startFind(dir)
		if s.finds == nil {
			s.finds = map[string]*findCache{}
		}
		s.finds[dir] = c
		// A picker closed for good leaves its cache: drop it once idle.
		time.AfterFunc(findIdle+time.Second, s.sweepFinds)
	}
	c.mu.Lock()
	c.used = now
	c.mu.Unlock()
	return c
}

func (s *Server) sweepFinds() {
	s.findMu.Lock()
	defer s.findMu.Unlock()
	s.sweepFindsLocked(time.Now())
}

// sweepFindsLocked drops the caches nothing has asked of lately.
func (s *Server) sweepFindsLocked(now time.Time) {
	for dir, c := range s.finds {
		c.mu.Lock()
		idle := now.Sub(c.used) > findIdle
		c.mu.Unlock()
		if idle {
			c.cancel()
			delete(s.finds, dir)
		}
	}
}

// closeFinds ends every scan, for Close.
func (s *Server) closeFinds() {
	s.findMu.Lock()
	defer s.findMu.Unlock()
	for dir, c := range s.finds {
		c.cancel()
		delete(s.finds, dir)
	}
}

// startFind scans dir on goroutines of its own: with fd, or by walking.
func (s *Server) startFind(dir string) *findCache {
	ctx, cancel := context.WithCancel(context.Background())
	c := &findCache{root: dir, cancel: cancel, used: time.Now()}
	if fd := fdPath(); fd != "" {
		c.tool = "fd"
		go c.runFd(ctx, fd)
	} else {
		c.tool = "walk"
		go c.walk(ctx)
	}
	return c
}

// fdPath finds fd on PATH (fdfind, as Debian names it), found once.
var fdPath = sync.OnceValue(func() string {
	for _, name := range []string{"fd", "fdfind"} {
		if p, err := exec.LookPath(name); err == nil {
			return p
		}
	}
	return ""
})

// runFd scans with fd: its directories and its files, two processes at
// once, since fd doesn't mark which is which in one listing. Hidden
// entries are skipped and .gitignore honored, as fd does by default.
func (c *findCache) runFd(ctx context.Context, fd string) {
	defer c.end()
	ctx, stop := context.WithCancel(ctx)
	defer stop()
	var wg sync.WaitGroup
	for _, kind := range []struct {
		dir  bool
		args []string
	}{
		{true, []string{"--type", "d"}},
		{false, []string{"--type", "f", "--type", "l"}},
	} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			args := append([]string{"--color=never", "--base-directory", c.root, "--strip-cwd-prefix", "-0"}, kind.args...)
			args = append(args, ".")
			cmd := exec.CommandContext(ctx, fd, args...)
			hideWindow(cmd)
			out, err := cmd.StdoutPipe()
			if err != nil {
				return
			}
			if err := cmd.Start(); err != nil {
				return
			}
			r := bufio.NewReaderSize(out, 64*1024)
			for {
				line, err := r.ReadBytes(0)
				if len(line) > 1 {
					rel := strings.TrimSuffix(string(line[:len(line)-1]), "\n")
					rel = filepath.ToSlash(rel)
					rel = strings.TrimPrefix(rel, "./")
					rel = strings.TrimSuffix(rel, "/")
					if rel != "" && rel != "." && !c.add(rel, kind.dir) {
						stop()
						break
					}
				}
				if err != nil {
					break
				}
			}
			// Ended early: fd is killed, and its exit is of no interest.
			_ = cmd.Wait()
		}()
	}
	wg.Wait()
}

// walk scans without fd: every entry under the root but dot-names and
// findSkip's, not following symlinks, in directory order.
func (c *findCache) walk(ctx context.Context) {
	defer c.end()
	root := c.root
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == root {
			return nil
		}
		if ctx.Err() != nil {
			return fs.SkipAll
		}
		name := d.Name()
		if strings.HasPrefix(name, ".") || findSkip[name] {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return nil
		}
		if !c.add(filepath.ToSlash(rel), d.IsDir()) {
			return fs.SkipAll
		}
		return nil
	})
}

// findHit is one entry the query matches.
type findHit struct {
	idx   int
	score int
	pos   []int
}

// findRank is the entries under prefix that match query, best first,
// the first limit of them with their positions, and how many matched
// in all. The query's space-separated terms must all match (fzf's
// extended mode, without its operators); each scores by fzf's
// FuzzyMatchV2, case-insensitively unless it has a capital, and the
// scores add up. Ties go to the shorter path, then scan order.
func findRank(entries []findEntry, prefix, query string, limit int) ([]findHit, int) {
	terms := findTerms(query)
	var hits []findHit
	if len(terms) == 0 {
		for i, e := range entries {
			if strings.HasPrefix(e.path, prefix) {
				hits = append(hits, findHit{idx: i, pos: []int{}})
			}
		}
	} else {
		hits = findScore(entries, prefix, terms)
		sort.SliceStable(hits, func(a, b int) bool {
			x, y := hits[a], hits[b]
			if x.score != y.score {
				return x.score > y.score
			}
			return len(entries[x.idx].path) < len(entries[y.idx].path)
		})
	}
	matched := len(hits)
	if len(hits) > limit {
		hits = hits[:limit]
	}
	if len(terms) > 0 {
		slab := util.MakeSlab(100*1024, 2048)
		for i := range hits {
			hits[i].pos = findPositions(entries[hits[i].idx].path[len(prefix):], terms, slab)
		}
	}
	return hits, matched
}

// findTerm is one word of the query, as the matcher takes it.
type findTerm struct {
	runes         []rune
	caseSensitive bool
}

func findTerms(query string) []findTerm {
	var terms []findTerm
	for _, word := range strings.Fields(query) {
		t := findTerm{caseSensitive: strings.IndexFunc(word, unicode.IsUpper) >= 0}
		if !t.caseSensitive {
			word = strings.ToLower(word)
		}
		// Accents fold on both sides, as fzf's default has them.
		t.runes = algo.NormalizeRunes([]rune(word))
		terms = append(terms, t)
	}
	return terms
}

// findScore scores every entry under prefix against the terms, across
// the CPUs when there are many.
func findScore(entries []findEntry, prefix string, terms []findTerm) []findHit {
	workers := 1
	if len(entries) > findParallel {
		workers = min(goruntime.NumCPU(), 8, (len(entries)+findParallel-1)/findParallel)
	}
	chunk := (len(entries) + workers - 1) / workers
	parts := make([][]findHit, workers)
	var wg sync.WaitGroup
	for w := range workers {
		lo, hi := w*chunk, min((w+1)*chunk, len(entries))
		wg.Add(1)
		go func() {
			defer wg.Done()
			slab := util.MakeSlab(100*1024, 2048)
			var hits []findHit
			for i := lo; i < hi; i++ {
				e := entries[i]
				if !strings.HasPrefix(e.path, prefix) {
					continue
				}
				chars := util.ToChars([]byte(e.path[len(prefix):]))
				score, ok := findMatchAll(&chars, terms, slab)
				if ok {
					hits = append(hits, findHit{idx: i, score: score})
				}
			}
			parts[w] = hits
		}()
	}
	wg.Wait()
	return slices.Concat(parts...)
}

// findMatchAll is the terms' summed score on text, if every one matches.
func findMatchAll(text *util.Chars, terms []findTerm, slab *util.Slab) (int, bool) {
	score := 0
	for _, t := range terms {
		res, _ := algo.FuzzyMatchV2(t.caseSensitive, true, true, text, t.runes, false, slab)
		if res.Start < 0 {
			return 0, false
		}
		score += res.Score
	}
	return score, true
}

// findPositions is the rune offsets in text that the terms match,
// ascending, each once.
func findPositions(text string, terms []findTerm, slab *util.Slab) []int {
	chars := util.ToChars([]byte(text))
	var pos []int
	for _, t := range terms {
		_, p := algo.FuzzyMatchV2(t.caseSensitive, true, true, &chars, t.runes, true, slab)
		if p != nil {
			pos = append(pos, *p...)
		}
	}
	slices.Sort(pos)
	pos = slices.Compact(pos)
	if pos == nil {
		pos = []int{}
	}
	return pos
}
