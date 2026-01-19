# AI Developer Collaboration Guide

This guide is for AI assistants (like Claude Code) working on the Sonos Volume Controller project. It covers available tools, agents, commands, and best practices for effective collaboration.

---

## Quick Reference

### Available Slash Commands

**`/start [optional focus area]`**
- Automated workflow to begin new work
- Checks for open PRs, returns to main, suggests next tasks from GitHub issues (prio labels)
- Creates feature branch and applies `status:in-progress` to the selected issue
- Presents implementation plan before coding

**`/finish [optional context]`**
- Checklist to complete current work
- Guides through PR creation, CHANGELOG + issue status updates
- Tracks technical debt

**`/security-review [file or directory]`**
- Reviews code for security vulnerabilities
- Use proactively before PRs

---

## Available Specialized Agents

### Development & Architecture

**`architecture-advisor`**
- Use when: Starting new features, completing significant code changes, refactoring
- Provides: Architectural guidance, design pattern recommendations, dependency analysis
- Example: After implementing a new service layer or before starting a major feature

**`ux-ui-designer`**
- Use when: Designing UI, creating wireframes, optimizing UX, accessibility improvements
- Provides: Design specifications, interaction patterns, user flow optimization
- Example: Before implementing menu bar UI changes or HUD improvements

**`zapier-zinnia-engineer`**
- Use when: Working with design system components (not applicable to this Swift project)
- Note: This agent is for Zapier's React design system - not relevant here

### Product Management (from global CLAUDE.md)

**`discovery-documenter`**
- Use when: Before/during prototyping to formalize learnings
- Provides: Problem Discovery and Solution Exploration documents
- Example: When exploring a new feature like "multi-room scene support"

**`requirements-writer`**
- Use when: Prototype validated and PRD needed
- Provides: Formal PRD with press release format
- Example: After validating an approach for a major feature

**`ticket-breaker`**
- Use when: PRD finalized and ready for engineering handoff
- Provides: Sequenced JIRA ticket breakdown
- Example: Breaking down a complex feature into implementation tasks

**`enterprise-risk-spotter`**
- Use when: Proactively reviewing features for enterprise concerns
- Provides: Security, compliance, scalability risk analysis
- Example: Before implementing network features or data storage

---

## Project-Specific Workflow

### 1. Starting Work

**Always use `/start` command** - it automates:
1. Checking for open PRs
2. Returning to main branch
3. Suggesting prioritized tasks from GitHub issues (prio labels)
4. Creating appropriately named branch
5. Applying `status:in-progress` and commenting with the branch name
6. Launching appropriate agent if needed

**Branch naming:**
- Bugs: `bug/descriptive-name`
- Features: `feature/descriptive-name`
- Enhancements: `enhancement/descriptive-name`

### 2. During Development

**Use TodoWrite tool for multi-step tasks**
- Break complex work into trackable steps
- Mark tasks in_progress/completed as you go
- Never batch completions - mark done immediately

**Consult Sonos API docs** (`docs/sonos-api/`) before implementing:
- `volume.md` - Volume control patterns
- `groups.md` - Group management
- `upnp-local-api.md` - SOAP API reference

**Testing commands:**
```bash
# Quick iteration
swift run

# Kill and restart
pkill SonosVolumeController && swift run

# Build .app bundle
./build-app.sh

# Build and install to /Applications
./build-app.sh --install
```

### 3. Completing Work

**Use `/finish` command** - it guides through:
1. Testing (swift build -c release)
2. CHANGELOG.md update (without PR number)
3. Issue cleanup (remove `status:in-progress`, close issue)
4. Commit and push
5. PR creation with gh pr create
6. CHANGELOG.md update (add PR number)

**Two-stage CHANGELOG.md update is required:**
- First: Add entry without PR number before creating PR
- Second: Add PR number after GitHub assigns it

**Commit message format:**
```
Feature: Description

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

---

## Architecture Overview

### Key Components

| File | Responsibility |
|------|---------------|
| `main.swift` | App entry point, initialization |
| `VolumeKeyMonitor.swift` | F11/F12 hotkey capture via event tap |
| `AudioDeviceMonitor.swift` | Tracks active audio output device |
| `SonosController.swift` | Sonos device discovery and control (actor) |
| `VolumeHUD.swift` | On-screen volume display (Liquid Glass HUD) |
| `MenuBarContentView.swift` | Menu bar popover UI |
| `PreferencesWindow.swift` | Settings window |

### Infrastructure Layer

| File | Responsibility |
|------|---------------|
| `SSDPSocket.swift` | UDP multicast socket for device discovery |
| `SSDPDiscoveryService.swift` | SSDP protocol implementation |
| `SonosNetworkClient.swift` | Type-safe SOAP API client |
| `XMLParsingHelpers.swift` | XML parsing utilities |

### Important Patterns

1. **Audio Device Trigger**: Only intercept volume keys when specific audio device is active
2. **Topology Loading**: Must discover devices + load topology before selecting speaker
3. **Stereo Pairs**: Query visible speaker (it controls both in pair)
4. **@MainActor**: VolumeHUD and UI components require main actor isolation
5. **Actor Isolation**: SonosController is an actor - use async/await

### Recent Architecture Work

- **Infrastructure extraction**: Reduced SonosController from 1,732 to 1,471 lines
- **SOAP migration**: All operations now use SonosNetworkClient
- **Actor conversion**: Thread-safe async/await patterns throughout
- **Real-time topology**: UPnP event subscriptions for group changes

---

## Agent Usage Recommendations

### When to Launch Agents

**Before starting complex features:**
```
User: "I want to add basic playback controls"
You: [Launch architecture-advisor to plan component structure]
```

**After completing significant code:**
```
[Complete refactoring of MenuBarContentView]
You: [Launch architecture-advisor to review changes]
```

**For UX improvements:**
```
User: "The group expansion click target is too small"
You: [Launch ux-ui-designer for interaction pattern recommendations]
```

**For feature discovery:**
```
User: "I'm thinking about multi-room scene support"
You: [Launch discovery-documenter to formalize the exploration]
```

### Agent Coordination

**Run agents in parallel when possible:**
```swift
// Single message with multiple Task tool calls
[Launch architecture-advisor and ux-ui-designer simultaneously]
```

**Sequential agent workflow:**
1. `discovery-documenter` - Explore and document problem/solution
2. `requirements-writer` - Create formal PRD
3. `ticket-breaker` - Break into implementation tasks
4. Execute tasks with `architecture-advisor` and `ux-ui-designer` as needed

---

## Common Scenarios

### Scenario 1: Bug Fix
```
1. /start bug/descriptive-name
2. Use TodoWrite to track investigation + fix steps
3. Test with swift run
4. /finish (creates PR, updates docs)
```

### Scenario 2: New Feature
```
1. /start feature/descriptive-name
2. [Optional] Launch discovery-documenter if exploration needed
3. Launch architecture-advisor for design guidance
4. Launch ux-ui-designer for UI/UX design
5. Use TodoWrite to track implementation
6. Test thoroughly (swift run, ./build-app.sh --install)
7. /finish
```

### Scenario 3: Architecture Refactoring
```
1. /start refactor/descriptive-name
2. Launch architecture-advisor for refactoring strategy
3. Use TodoWrite for step-by-step refactoring plan
4. Make incremental changes with tests between each
5. Launch architecture-advisor again to review completed work
6. /finish
```

### Scenario 4: Enhancement
```
1. /start enhancement/descriptive-name
2. Launch ux-ui-designer if UI changes involved
3. Use TodoWrite for implementation steps
4. Test with swift run
5. /finish
```

---

## Sonos API Critical Knowledge

### Group Volume Behavior (from `docs/sonos-api/volume.md`)

- **SetGroupVolume**: Sets absolute volume, maintains speaker ratios
- **SetRelativeGroupVolume**: Adjusts incrementally, maintains speaker ratios
- Both commands preserve relative volume differences between speakers

### Coordinator Selection (from `docs/sonos-api/groups.md`)

- First speaker in group becomes coordinator
- Playing speakers should be prioritized as coordinators
- Line-in sources are device-specific and cannot be shared
- Stereo pairs have limitations as coordinators

### Common Pitfalls

1. **Don't assume group volume is sum of individual volumes** - it's proportional
2. **Always load topology before operations** - device discovery alone isn't enough
3. **Stereo pairs count as one device** - query the visible speaker
4. **Line-in audio requires special handling** - can't be shared across groups

---

## Git Workflow Best Practices

### Pre-work Checklist
- [ ] Check for open PRs (`gh pr list --author @me --state open`)
- [ ] Ensure on main branch (`git branch --show-current`)
- [ ] Pull latest changes (`git pull`)
- [ ] Check GitHub issues with `status:in-progress` for conflicts

### During Work
- [ ] Create appropriately named branch
- [ ] Apply `status:in-progress` label and comment with branch name
- [ ] Commit frequently with descriptive messages
- [ ] Test before committing

### Post-work Checklist
- [ ] Update CHANGELOG.md (without PR number)
- [ ] Remove `status:in-progress` and close the issue
- [ ] Commit and push
- [ ] Create PR with `gh pr create`
- [ ] Update CHANGELOG.md (add PR number)
- [ ] Push PR number update

---

## Communication Guidelines

### Be Concise
- Keep responses under 4 lines for simple tasks
- Match detail level to task complexity
- No unnecessary preamble/postamble

### Be Proactive
- Use TodoWrite for multi-step tasks
- Launch appropriate agents without asking
- Run git commands automatically
- Call out when you're launching an agent and why

### Ask When Unclear
- Multiple possible approaches
- User preference needed
- Architectural decisions with tradeoffs

---

## Tool Usage Tips

### File Operations
- **Read**: Use for viewing files (supports images, PDFs, notebooks)
- **Edit**: Use for surgical string replacements
- **Write**: Only for new files (prefer Edit for existing files)
- **Glob**: Find files by pattern
- **Grep**: Search file contents

### Batch Tool Calls
- Run independent commands in parallel (single message, multiple tool calls)
- Example: `git status` + `git diff` + `git log` simultaneously

### Bash Tool
- For terminal operations only (git, npm, swift, etc.)
- NOT for file operations - use specialized tools
- Quote paths with spaces: `cd "path with spaces"`
- Chain dependent commands with `&&`

---

## Anti-Patterns to Avoid

❌ **Don't create files unnecessarily** - prefer editing existing files
❌ **Don't create documentation proactively** - only when explicitly requested
❌ **Don't batch todo completions** - mark done immediately
❌ **Don't skip CHANGELOG.md PR number update** - it's a two-stage process
❌ **Don't use bash for file reading** - use Read tool
❌ **Don't commit without testing** - always run swift build or swift run first
❌ **Don't work on "In Progress" items** - check `status:in-progress` first

---

## Success Metrics

You're doing well when:
- ✅ PRs are focused on single feature/bug/enhancement
- ✅ CHANGELOG.md and GitHub issues stay in sync
- ✅ Commits have proper format and co-authorship
- ✅ TodoWrite shows clear progress tracking
- ✅ Appropriate agents launched for complex work
- ✅ Sonos API docs consulted before implementation
- ✅ Architecture patterns followed (actor isolation, @MainActor, etc.)

---

## Getting Help

- **GitHub Issues** - Current priorities and known issues
- **CHANGELOG.md** - Historical context for decisions
- **CLAUDE.md** - Project-specific collaboration guidelines
- **CONTRIBUTING.md** - Detailed collaboration guidelines
- **docs/sonos-api/** - Official Sonos API documentation

When in doubt: Ask the user or launch an appropriate agent for guidance.
