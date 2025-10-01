# Claude Collaboration Guide

This document guides collaboration between Claude and the developer on the Sonos Volume Controller project.

## Workflow

### 1. Picking Next Task

Review `ROADMAP.md` and select from:
- **Planned Features**: Major new functionality
- **Enhancements**: Improvements to existing features
- **Known Bugs**: Issues that need fixing
- **App Store Readiness**: Tasks for App Store submission

Check the "In Progress" section to see what's already being worked on to avoid conflicts.

Discuss with the user which task to tackle next.

### 2. Starting Work

1. **Create branch from main**: Use descriptive naming
   - Features: `feature/descriptive-name`
   - Enhancements: `enhancement/descriptive-name`
   - Bugs: `bug/descriptive-name`

2. **Mark as In Progress**: Add to `ROADMAP.md` "In Progress" section
   ```markdown
   ## In Progress
   - **Your task description** (branch: feature/task-name, @username)
   ```

3. **Plan mode**: Present implementation plan before coding

4. **Track progress**: Use TodoWrite tool for multi-step tasks

### 3. Completing Work

1. **Test**: Build with `swift build -c release` or `swift run`

2. **Update documentation** (first time - without PR number):
   - Add to `CHANGELOG.md` under appropriate section (Added/Changed/Fixed)
   - Example: `- First launch onboarding with welcome banner`
   - Remove from "In Progress" section in `ROADMAP.md`
   - Remove from planned work section in `ROADMAP.md` if applicable
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

### 4. After Merge

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
- **MenuBarContentView.swift**: Menu bar popover UI
- **PreferencesWindow.swift**: Settings window

### Important Patterns

1. **Audio Device Trigger**: Only intercept volume keys when specific audio device is active
2. **Topology Loading**: Must discover devices + load topology before selecting speaker
3. **Stereo Pairs**: Query visible speaker (it controls both in pair)
4. **@MainActor**: VolumeHUD and UI components require main actor isolation

## Tips for Development

- Always check `ROADMAP.md` at start of session
- Check "In Progress" section before starting work to avoid conflicts
- Use `swift run` for quick iteration during development
- Only use `./build-app.sh --install` when ready to test installed behavior
- Keep PRs focused on single feature/enhancement/bug
- See `CONTRIBUTING.md` for detailed collaboration guidelines