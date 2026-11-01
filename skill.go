// Package squish is the root of the module: it carries what the squish
// CLI ships beside its code and the daemon's own protocol, so a build
// hands out what matches it.
package squish

import _ "embed"

// Skill is skills/squish/SKILL.md, the skill that teaches an agent to
// drive squish from a pane; `squish skill install` writes it out.
//
//go:embed skills/squish/SKILL.md
var Skill string
