package daemon

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite the window's heir fixtures")

// show prints a tree compactly: panes by their number in the tab,
// splits as r(share:node ...) or c(...), and a child's From as
// share@from:node.
func show(n *Node) string {
	if n == nil {
		return "nil"
	}
	if n.IsLeaf() {
		return fmt.Sprint(n.Pane.N)
	}
	var b strings.Builder
	if n.Axis == Row {
		b.WriteString("r(")
	} else {
		b.WriteString("c(")
	}
	for i, c := range n.Children {
		if i > 0 {
			b.WriteString(" ")
		}
		fmt.Fprintf(&b, "%d", c.Share)
		if !c.From.IsZero() {
			fmt.Fprintf(&b, "@%d", c.From.N)
		}
		fmt.Fprintf(&b, ":%s", show(c.Node))
	}
	b.WriteString(")")
	return b.String()
}

// pid is pane n of the tests' one tab.
func pid(n uint32) PaneID { return PaneID{WS: 1, Tab: 1, N: n} }

func pids(ns ...uint32) []PaneID {
	out := make([]PaneID, len(ns))
	for i, n := range ns {
		out[i] = pid(n)
	}
	return out
}

func mustSplit(t *testing.T, root *Node, target, pane uint32, dir Direction, share uint16) *Node {
	t.Helper()
	r, err := splitNode(root, pid(target), pid(pane), dir, share)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestSplit(t *testing.T) {
	r := leaf(pid(1))
	r = mustSplit(t, r, 1, 2, Right, 5000)
	if got := show(r); got != "r(5000:1 5000@1:2)" {
		t.Errorf("right of the root: %s", got)
	}
	// Same axis joins the split, carving from the target's share.
	r = mustSplit(t, r, 2, 3, Right, 5000)
	if got := show(r); got != "r(5000:1 2500@1:2 2500@2:3)" {
		t.Errorf("right again: %s", got)
	}
	// The other axis nests.
	r = mustSplit(t, r, 1, 4, Down, 3000)
	if got := show(r); got != "r(5000:c(7000:1 3000@1:4) 2500@1:2 2500@2:3)" {
		t.Errorf("down: %s", got)
	}
	// Left and up go before.
	r = mustSplit(t, r, 3, 5, Left, 4000)
	if got := show(r); got != "r(5000:c(7000:1 3000@1:4) 2500@1:2 1000@3:5 1500@2:3)" {
		t.Errorf("left: %s", got)
	}
	r = mustSplit(t, r, 2, 6, Up, 5000)
	if got := show(r); got != "r(5000:c(7000:1 3000@1:4) 2500@1:c(5000@2:6 5000:2) 1000@3:5 1500@2:3)" {
		t.Errorf("up: %s", got)
	}
	if err := Validate(r, pids(1, 2, 3, 4, 5, 6)); err != nil {
		t.Errorf("result invalid: %v", err)
	}
	if fmt.Sprint(r.Panes()) != fmt.Sprint(pids(1, 4, 6, 2, 5, 3)) {
		t.Errorf("order %v", r.Panes())
	}
	if _, err := splitNode(r, pid(99), pid(7), Right, 5000); err == nil {
		t.Error("split of a missing pane")
	}
	if _, err := splitNode(r, pid(1), pid(7), Right, Whole); err == nil {
		t.Error("split taking everything")
	}
}

type removeCase struct {
	name  string
	tree  func() *Node
	start string
	close uint32
	want  string
}

// removeCases close panes: the space goes back to where it came from,
// else the siblings grow in proportion.
func removeCases(t *testing.T) []removeCase {
	// A 5000, B 2500, C 2500, C split from B.
	chain := func() *Node {
		r := mustSplit(t, leaf(pid(1)), 1, 2, Right, 5000)
		return mustSplit(t, r, 2, 3, Right, 5000)
	}
	thirds := func() *Node {
		return &Node{Axis: Row, Children: []Child{{Share: 3334, Node: leaf(pid(1))}, {Share: 3333, Node: leaf(pid(2))}, {Share: 3333, Node: leaf(pid(3))}}}
	}
	return []removeCase{
		{"the newest goes back to its origin", chain, "r(5000:1 2500@1:2 2500@2:3)", 3, "r(5000:1 5000@1:2)"},
		{"split off to the left", func() *Node {
			r := mustSplit(t, leaf(pid(2)), 2, 1, Right, 5000)
			return mustSplit(t, r, 2, 3, Left, 5000)
		}, "r(2500@2:3 2500:2 5000@2:1)", 3, "r(5000:2 5000@2:1)"},
		{"the middle of a chain goes to what was split from it", chain, "r(5000:1 2500@1:2 2500@2:3)", 2, "r(5000:1 5000@1:3)"},
		{"the nearest split from it", func() *Node {
			return mustSplit(t, chain(), 2, 4, Right, 5000)
		}, "r(5000:1 1250@1:2 1250@2:4 2500@2:3)", 2, "r(5000:1 2500@1:4 2500@4:3)"},
		{"laid out evenly, siblings grow in proportion", thirds, "r(3334:1 3333:2 3333:3)", 2, "r(5000:1 5000:3)"},
		{"joined at an edge", func() *Node {
			return joinEdge(leaf(pid(1)), pid(2), Right)
		}, "r(5000:1 5000:2)", 2, "1"},
		{"to the split holding its origin", func() *Node {
			return mustSplit(t, chain(), 2, 4, Down, 5000)
		}, "r(5000:1 2500@1:c(5000:2 5000@2:4) 2500@2:3)", 3, "r(5000:1 5000@1:c(5000:2 5000@2:4))"},
		{"a collapsed split's slot keeps its From", func() *Node {
			return removeNode(mustSplit(t, chain(), 2, 4, Down, 5000), pid(3))
		}, "r(5000:1 5000@1:c(5000:2 5000@2:4))", 4, "r(5000:1 5000@1:2)"},
		{"a missing pane", thirds, "r(3334:1 3333:2 3333:3)", 99, "r(3334:1 3333:2 3333:3)"},
		{"down to one pane", func() *Node {
			return mustSplit(t, leaf(pid(1)), 1, 2, Right, 5000)
		}, "r(5000:1 5000@1:2)", 1, "2"},
		{"the last pane", func() *Node { return leaf(pid(1)) }, "1", 1, "nil"},
	}
}

func TestRemove(t *testing.T) {
	for _, c := range removeCases(t) {
		r := c.tree()
		if got := show(r); got != c.start {
			t.Errorf("%s: starts as %s, want %s", c.name, got, c.start)
			continue
		}
		if got := show(removeNode(r, pid(c.close))); got != c.want {
			t.Errorf("%s: closing %d gives %s, want %s", c.name, c.close, got, c.want)
		}
	}
}

// heirFixtures is where the window's Tab.zig test reads the cases, so
// one rule has one set of answers in both places.
const heirFixtures = "../../clients/gui/src/testdata/heir.json"

// TestHeirFixtures checks the fixtures are the cases' (go test -update
// rewrites them): each tree, the pane closed, and the tree after.
func TestHeirFixtures(t *testing.T) {
	type fixture struct {
		Name  string `json:"name"`
		Tree  *Node  `json:"tree"`
		Close PaneID `json:"close"`
		Want  *Node  `json:"want"`
	}
	var out []fixture
	for _, c := range removeCases(t) {
		tree := c.tree()
		if !holds(tree, pid(c.close)) || tree.IsLeaf() {
			continue
		}
		want := removeNode(c.tree(), pid(c.close))
		out = append(out, fixture{c.name, tree, pid(c.close), want})
	}
	b, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	b = append(b, '\n')
	if *update {
		if err := os.WriteFile(heirFixtures, b, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	have, err := os.ReadFile(heirFixtures)
	if err != nil || !bytes.Equal(bytes.ReplaceAll(have, []byte("\r\n"), []byte("\n")), b) {
		t.Errorf("%s is stale (%v): go test ./internal/daemon -run TestHeirFixtures -update", heirFixtures, err)
	}
}

// TestSplitCloseRestores splits each pane of a tree every way and
// closes the new pane: the tree comes back as it was.
func TestSplitCloseRestores(t *testing.T) {
	bases := []*Node{
		leaf(pid(1)),
		{Axis: Row, Children: []Child{
			{Share: 3000, Node: &Node{Axis: Column, Children: []Child{{Share: 6000, Node: leaf(pid(1))}, {Share: 4000, From: pid(1), Node: leaf(pid(4))}}}},
			{Share: 4500, From: pid(1), Node: leaf(pid(2))},
			{Share: 2500, From: pid(2), Node: leaf(pid(3))},
		}},
	}
	for _, base := range bases {
		want := show(base)
		for _, target := range base.Panes() {
			for _, dir := range []Direction{Right, Down, Left, Up} {
				for share := uint16(1000); share < Whole; share += 1000 {
					r, err := splitNode(base.Clone(), target, pid(99), dir, share)
					if err != nil {
						t.Fatal(err)
					}
					if got := show(removeNode(r, pid(99))); got != want {
						t.Errorf("%s of %d by %d: %s, want %s", dir, target.N, share, got, want)
					}
				}
			}
		}
	}
}

// checkFrom fails unless every From in n names a pane in a sibling's
// subtree.
func checkFrom(t *testing.T, n *Node, step string) {
	t.Helper()
	before := show(n)
	normalize(n)
	if after := show(n); after != before {
		t.Fatalf("%s: a From out of place\n%s\nnormalized\n%s", step, before, after)
	}
}

// TestFromInvariant moves panes as pane.move does, taking them out and
// putting them back along an edge: a moved pane forgets its origin, and
// what was split from it goes with its region.
func TestFromInvariant(t *testing.T) {
	chain := func() *Node {
		return mustSplit(t, mustSplit(t, leaf(pid(1)), 1, 2, Right, 5000), 2, 3, Right, 5000)
	}
	// To the bottom edge: C takes B's place, with B's origin.
	r := joinEdge(removeNode(chain(), pid(2)), pid(2), Down)
	checkFrom(t, r, "to the bottom")
	if got := show(r); got != "c(5000:r(5000:1 5000@1:3) 5000:2)" {
		t.Errorf("to the bottom: %s", got)
	}
	if got := show(removeNode(r.Clone(), pid(3))); got != "c(5000:1 5000:2)" {
		t.Errorf("then closing C: %s", got)
	}

	// To another tab: nothing left here names it.
	r = removeNode(chain(), pid(2))
	checkFrom(t, r, "to another tab")
	if got := show(r); got != "r(5000:1 5000@1:3)" {
		t.Errorf("the tab it left: %s", got)
	}
	other := joinEdge(leaf(pid(7)), pid(2), Right)
	checkFrom(t, other, "into another tab")
	if got := show(other); got != "r(5000:7 5000:2)" {
		t.Errorf("in the other tab: %s", got)
	}
}

// TestSharesDontDrift splits and removes many times; every split's
// shares must still sum to exactly Whole.
func TestSharesDontDrift(t *testing.T) {
	r := leaf(pid(1))
	ids := []uint32{1}
	next := uint32(2)
	for i := range 300 {
		target := ids[(i*7)%len(ids)]
		dirs := []Direction{Right, Down, Left, Up}
		r = mustSplit(t, r, target, next, dirs[i%4], uint16(1000+(i*37)%8000))
		ids = append(ids, next)
		next++
		if i%3 == 2 {
			gone := ids[(i*5)%len(ids)]
			r = removeNode(r, pid(gone))
			for j, id := range ids {
				if id == gone {
					ids = append(ids[:j], ids[j+1:]...)
					break
				}
			}
		}
		if err := Validate(r, pids(ids...)); err != nil {
			t.Fatalf("step %d: %v\n%s", i, err, show(r))
		}
		checkFrom(t, r, fmt.Sprint("step ", i))
	}
}

func TestValidate(t *testing.T) {
	good := &Node{Axis: Row, Children: []Child{{Share: 4000, Node: leaf(pid(1))}, {Share: 6000, Node: leaf(pid(2))}}}
	if err := Validate(good, pids(2, 1)); err != nil {
		t.Errorf("good tree: %v", err)
	}
	bad := map[string]*Node{
		"sum":       {Axis: Row, Children: []Child{{Share: 4000, Node: leaf(pid(1))}, {Share: 5000, Node: leaf(pid(2))}}},
		"one child": {Axis: Row, Children: []Child{{Share: Whole, Node: leaf(pid(1))}}},
		"axis":      {Axis: 9, Children: []Child{{Share: 5000, Node: leaf(pid(1))}, {Share: 5000, Node: leaf(pid(2))}}},
		"duplicate": {Axis: Row, Children: []Child{{Share: 5000, Node: leaf(pid(1))}, {Share: 5000, Node: leaf(pid(1))}}},
		"zero":      {Axis: Row, Children: []Child{{Share: 0, Node: leaf(pid(1))}, {Share: Whole, Node: leaf(pid(2))}}},
	}
	for name, n := range bad {
		if err := Validate(n, pids(1, 2)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if err := Validate(good, pids(1, 3)); err == nil {
		t.Error("different panes accepted")
	}
}

func TestMeasure(t *testing.T) {
	r := leaf(pid(1))
	r = mustSplit(t, r, 1, 2, Right, 2500)
	r = mustSplit(t, r, 1, 3, Down, 5000)
	unit := func(PaneID) (uint32, uint32) { return 1, 1 }
	// r(7500:c(5000:1 5000:3) 2500:2) in 101x41 one-pixel cells.
	m := Measure(r, 101, 41, unit)
	want := map[PaneID][2]uint16{pid(1): {75, 20}, pid(3): {75, 21}, pid(2): {26, 41}}
	if fmt.Sprint(m) != fmt.Sprint(want) {
		t.Errorf("sizes %v, want %v", m, want)
	}
	// Too small to share: everyone still gets a cell.
	tiny := Measure(r, 1, 1, unit)
	for id, s := range tiny {
		if s[0] < 1 || s[1] < 1 {
			t.Errorf("pane %s got %v", id, s)
		}
	}
}

// TestMeasureFonts: the shares divide pixels, and each pane's grid
// follows its own cell size.
func TestMeasureFonts(t *testing.T) {
	r := mustSplit(t, leaf(pid(1)), 1, 2, Right, 5000)
	cells := map[PaneID][2]uint32{pid(1): {10, 20}, pid(2): {20, 40}}
	m := Measure(r, 1000, 800, func(id PaneID) (uint32, uint32) { return cells[id][0], cells[id][1] })
	want := map[PaneID][2]uint16{pid(1): {50, 40}, pid(2): {25, 20}}
	if fmt.Sprint(m) != fmt.Sprint(want) {
		t.Errorf("sizes %v, want %v", m, want)
	}
}
