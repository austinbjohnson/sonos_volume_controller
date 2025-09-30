# Claude Collaboration Guide

This document guides collaboration between Claude and the developer on the Sonos Volume Controller project.

## Workflow

### 1. Picking Next Task

Review `FEATURES.md` and select from:
- **Features**: Major new functionality
- **Enhancements**: Improvements to existing features
- **Bugs**: Issues that need fixing
- **App Store Readiness**: Tasks for App Store submission

Discuss with the user which task to tackle next.

### 2. Starting Work

1. **Create branch from main**: Use descriptive naming
   - Features: `feature/descriptive-name`
   - Enhancements: `enhancement/descriptive-name`
   - Bugs: `bug/descriptive-name`

2. **Plan mode**: Present implementation plan before coding

3. **Track progress**: Use TodoWrite tool for multi-step tasks

### 3. Completing Work

1. **Test**: Build with `swift build -c release` or `swift run`

2. **Update FEATURES.md FIRST** (before committing):
   - Move completed item from Features/Enhancements/Bugs to "Completed Improvements"
   - Add entry with placeholder: `(PR #TBD)` or similar
   - This ensures the FEATURES.md update is included in the PR

3. **Commit**: Write clear commit message with emoji prefix
   ```
   🤖 Generated with [Claude Code](https://claude.com/claude-code)

   Co-Authored-By: Claude <noreply@anthropic.com>
   ```

4. **Create PR**: Use `gh pr create` with detailed description
   - GitHub will automatically assign a PR number
   - Optionally update FEATURES.md with actual PR number (but this can be done after merge too)

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

- Always check `FEATURES.md` at start of session
- Use `swift run` for quick iteration during development
- Only use `./build-app.sh --install` when ready to test installed behavior
- Keep PRs focused on single feature/enhancement/bug