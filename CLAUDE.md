# Claude Collaboration Guide

This document guides collaboration between Claude and the developer on the Sonos Volume Controller project.

## 🚀 CRITICAL: Agent-First Development Strategy

**ALWAYS USE AGENTS TO PRESERVE CONTEXT AND PARALLELIZE WORK**

This project requires aggressive agent usage to:
- **Preserve context window** - Agents have their own context, preventing main conversation bloat
- **Parallelize work** - Run multiple agents simultaneously for maximum efficiency
- **Deep dive without distraction** - Let agents handle detailed analysis while you orchestrate

### When to Use Agents (Almost Always!)

**Use agents by default for ANY task that involves:**
- Reading multiple files (use `codebase-analyzer`, `codebase-locator`, or `codebase-pattern-finder`)
- Searching for patterns or implementations (use `codebase-pattern-finder`)
- Understanding architecture or dependencies (use `codebase-analyzer`)
- Researching documentation (use `thoughts-locator` for docs/ or thoughts/)
- Any task requiring more than 2-3 file reads

### Agent Usage Patterns

#### Pattern 1: Parallel Analysis (Most Common)
When starting ANY new task, immediately launch agents in parallel:

```
Task: "Implement real-time transport state updates"

CORRECT ✅:
- Launch codebase-analyzer (find current metadata system) IN PARALLEL WITH
- Launch codebase-pattern-finder (find UPnP patterns) IN PARALLEL WITH
- Launch thoughts-locator (find relevant Sonos API docs)
→ All 3 agents run simultaneously, results come back together

WRONG ❌:
- Read MenuBarContentView.swift
- Read SonosController.swift
- Read UPnPEventListener.swift
- Read docs/sonos-api/upnp-local-api.md
→ Uses 4x the context, takes 4x longer
```

#### Pattern 2: Deep Dive Without Context Burn
When you need detailed understanding:

```
CORRECT ✅:
"I need to understand how volume control works"
→ Launch codebase-analyzer with specific prompt
→ Agent reads all relevant files, returns summary
→ You get the answer without burning 2000 tokens per file

WRONG ❌:
→ Read VolumeKeyMonitor.swift (800 lines)
→ Read SonosController.swift (1400 lines)
→ Read MenuBarContentView.swift (1600 lines)
→ Context window now at 60%
```

#### Pattern 3: Search Before Read
NEVER use Grep/Read for open-ended searches:

```
CORRECT ✅:
"Find where speakers are selected"
→ Launch codebase-locator agent
→ Agent searches, finds exact locations, returns targeted results

WRONG ❌:
→ Grep for "selectSpeaker"
→ Read MenuBarContentView.swift around that
→ Grep for related patterns
→ Read more files
→ Repeat 5x
```

### Available Agents & When to Use Them

#### Research & Analysis Agents
| Agent | Use When | Example |
|-------|----------|---------|
| **codebase-locator** | Finding files/components by feature description | "Find where volume hotkeys are handled" |
| **codebase-analyzer** | Understanding implementation details | "How does the SSDP discovery work?" |
| **codebase-pattern-finder** | Finding similar code or usage examples | "Show me how other SOAP commands are structured" |
| **thoughts-locator** | Finding documentation in docs/ or thoughts/ | "Find Sonos API documentation about events" |
| **thoughts-analyzer** | Deep research into documentation | "Understand the full UPnP event subscription flow" |

#### Operational Agents (CRITICAL - Use These Too!)
| Agent | Use When | Example |
|-------|----------|---------|
| **git-workflow-manager** | ANY Git/GitHub operations | "Create branch, commit changes, create PR" |
| **general-purpose** | Building, running, testing the app | "Build the app and check for errors, then run it and monitor logs for transport subscriptions" |

**⚠️ IMPORTANT: Don't manually run/test - use general-purpose agent!**
- Running `swift run` or `swift build` manually wastes context
- Use general-purpose agent to run, monitor logs, and report back
- Agent can filter logs, watch for specific patterns, and give you a summary

### Parallel Agent Execution

**ALWAYS run agents in parallel when tasks are independent:**

```swift
// Single message with multiple Task tool calls:
Task(codebase-analyzer: "Analyze blue dot implementation")
Task(codebase-locator: "Find now-playing metadata code")
Task(thoughts-locator: "Find Sonos transport state docs")
// All execute simultaneously!
```

### Default Agent Strategy

**For every new task:**
1. Immediately identify what you need to know
2. Launch 2-3 agents in parallel to gather information
3. Wait for results, then plan implementation
4. Only read specific files when you need to edit them
5. **After coding: Use general-purpose agent to test/run**

### Testing & Running Workflow

**WRONG ❌:**
```
You: "Let me build and test..."
→ Bash: swift build
→ Bash: swift run &
→ Wait/check logs manually
→ Context window filling up with build output
```

**CORRECT ✅:**
```
You: "Let me test this with an agent"
→ Task(general-purpose): "Build the app with swift build, check for errors.
   Then run it with swift run, monitor logs for 10 seconds, and look for:
   - Transport subscription messages (🎵)
   - Any errors or warnings
   Report back what you find."
→ Agent handles everything, returns concise summary
→ Zero context burn
```

**Remember:** Using agents is faster, cleaner, and preserves context for ALL work - research AND operations!

## Workflow

### 1. Picking Next Task

Review GitHub issues and select from:
- **P0/P1/P2/P3 priorities** via `prio:*` labels
- **Types** via `type:*` labels
- **App Store readiness** via `area:release`

Check `status:in-progress` to avoid conflicts.

Discuss with the user which task to tackle next.

### 2. Starting Work

**⚡ STEP 0: Launch Agents First!**

Before doing ANYTHING else, launch agents to gather context:
- Use `codebase-locator` to find relevant files
- Use `codebase-analyzer` to understand existing implementation
- Use `thoughts-locator` if Sonos API docs might be relevant
- **Run them in parallel** (single message with multiple Task calls)

1. **Create branch from main**: Use descriptive naming
   - Features: `feature/descriptive-name`
   - Enhancements: `enhancement/descriptive-name`
   - Bugs: `bug/descriptive-name`

2. **Mark as In Progress**: Apply `status:in-progress` to the issue and comment with the branch name

3. **Plan mode**: Present implementation plan before coding

4. **Track progress**: Use TodoWrite tool for multi-step tasks

### 3. Completing Work

1. **Test**: Use general-purpose agent to build and test
   - **Don't manually run swift build/swift run** - use agent to preserve context
   - Agent can build, run, monitor logs, and report issues

2. **Update documentation** (first time - without PR number):
   - Add to `CHANGELOG.md` under appropriate section (Added/Changed/Fixed)
   - Example: `- First launch onboarding with welcome banner`
   - Remove `status:in-progress` from the issue and close it
   - **Do NOT include PR number yet** (you don't have it)

3. **Commit and push**:
   ```bash
   git add -A
   git commit -m "Feature: Description

   🤖 Generated with [Claude Code](https://claude.com/claude-code)

   Co-Authored-By: Claude <noreply@anthropic.com>"
   git push -u origin branch-name
   ```

4. **Create PR**: Use `gh pr create` with detailed description
   - GitHub will assign a PR number (e.g., #24)

5. **Update CHANGELOG.md** (second time - add PR number):
   - Add the PR number to your entry
   - Example: `- First launch onboarding with welcome banner (PR #24)`
   - Commit and push:
   ```bash
   git commit -am "Add PR #24 to CHANGELOG"
   git push
   ```

This ensures the PR number is accurate in the branch before merging.

### 4. After Merge (use git)

User merges PR on GitHub, then locally:
```bash
git checkout main
git pull
```

## Development Commands

### Quick Testing
```bash
# Run directly without building .app
swift run

# Kill running instance first
pkill SonosVolumeController && swift run
```

### Building & Installing
```bash
# Build only (creates .app in project directory)
./build-app.sh

# Build and install to /Applications
./build-app.sh --install
```

### Git Workflow
```bash
# Create new branch
git checkout main
git pull
git checkout -b feature/name

# Commit changes
git add .
git commit -m "message"

# Push and create PR
git push -u origin feature/name
gh pr create --title "Title" --body "Description"
```

## Project Architecture

### Key Components

- **main.swift**: App entry point, initialization
- **VolumeKeyMonitor.swift**: Captures F11/F12 hotkeys via event tap
- **AudioDeviceMonitor.swift**: Tracks current audio output device
- **SonosController.swift**: Sonos device discovery and control
- **VolumeHUD.swift**: On-screen volume display (Liquid Glass HUD)
- **MenuBarContentView.swift**: Menu bar menu UI
- **PreferencesWindow.swift**: Settings window

### Important Patterns

1. **Audio Device Trigger**: Only intercept volume keys when specific audio device is active
2. **Topology Loading**: Must discover devices + load topology before selecting speaker
3. **Stereo Pairs**: Query visible speaker (it controls both in pair)
4. **@MainActor**: VolumeHUD and UI components require main actor isolation

## Sonos API Documentation

**Local docs available at:** `SonosVolumeController/docs/sonos-api/`

Key documentation files:
- **volume.md**: Volume control best practices, group vs individual volume
- **groups.md**: Group management, coordinator selection
- **upnp-local-api.md**: Local UPnP/SOAP API reference
- **control.md**: Cloud API overview (households, groups, sessions)

**Important:** Always consult local docs before implementing Sonos-related features to ensure compliance with official recommendations.

### Key Sonos Concepts

1. **Group Volume**: According to `volume.md`, group volume "Adjusts volume proportionally across all players in a group" and "Maintains relative volume differences between players"

2. **Both `SetGroupVolume` and `SetRelativeGroupVolume` maintain speaker ratios** - this is documented Sonos behavior

3. **Volume Commands**:
   - `setVolume` / `SetGroupVolume`: Set absolute volume level (maintains ratios)
   - `setRelativeVolume` / `SetRelativeGroupVolume`: Adjust volume incrementally (maintains ratios)

## Tips for Development

- **🚀 USE AGENTS FIRST** - Before reading any files, launch agents in parallel to gather context
- Always check GitHub issues at start of session (prio labels)
- Check `status:in-progress` before starting work to avoid conflicts
- **Consult `docs/sonos-api/` before implementing Sonos features** (use `thoughts-locator` agent!)
- Use `swift run` for quick iteration during development
- Only use `./build-app.sh --install` when ready to test installed behavior
- Keep PRs focused on single feature/enhancement/bug
- See `CONTRIBUTING.md` for detailed collaboration guidelines

### Agent Usage Checklist

**Before starting ANY task:**
- [ ] Can I use `codebase-locator` to find relevant files? (YES = use it)
- [ ] Do I need to understand existing code? (YES = use `codebase-analyzer`)
- [ ] Are there similar patterns I can follow? (YES = use `codebase-pattern-finder`)
- [ ] Is there API documentation I should read? (YES = use `thoughts-locator`)
- [ ] Can I run multiple agents in parallel? (Almost always YES)

**After making changes:**
- [ ] Do I need to test/build/run? (YES = use `general-purpose` agent)
- [ ] Do I need Git operations? (YES = use `git-workflow-manager` agent)

**Default answer:** Use agents for EVERYTHING - research, testing, and Git operations!
