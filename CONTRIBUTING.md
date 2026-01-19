# Contributing to Sonos Volume Controller

Thank you for your interest in contributing! This guide will help you understand our workflow and avoid conflicts when multiple developers are working on the project.

## Getting Started

1. **Check what's being worked on**: Review GitHub issues with `status:in-progress` to avoid duplicate work
2. **Pick a task**: Choose from GitHub issues using `prio:P0`–`prio:P3`
3. **Discuss if needed**: For major features, open an issue or discussion first

## Branch Naming Conventions

Use descriptive branch names with these prefixes:

- `feature/descriptive-name` - New functionality
- `enhancement/descriptive-name` - Improvements to existing features
- `bug/descriptive-name` - Bug fixes
- `docs/descriptive-name` - Documentation updates

**Examples:**
- `feature/real-time-topology-updates`
- `enhancement/improve-group-expand-ux`
- `bug/individual-speaker-volume`

## Workflow

### 1. Starting Work

```bash
# Update main branch
git checkout main
git pull

# Create your feature branch
git checkout -b feature/your-feature-name
```

**Mark your work in progress:**
- Apply the `status:in-progress` label to the issue
- Comment on the issue with your branch name

### 2. During Development

- Keep commits focused and atomic
- Write clear commit messages
- Test thoroughly with `swift run` or `swift build -c release`
- Update documentation as you go

### 3. Before Creating PR

**Test your changes:**
```bash
# Quick test
swift run

# Full build test
swift build -c release

# Test installed behavior
./build-app.sh --install
```

**Update documentation:**

1. Add your completed item to `CHANGELOG.md`:
   ```markdown
   ### Added
   - Your feature description
   ```

2. Remove `status:in-progress` and close the issue

### 4. Creating Pull Request

```bash
# Commit all changes including docs
git add -A
git commit -m "Feature: Brief description

Detailed explanation of changes

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Your Name <your.email@example.com>"

# Push to your branch
git push -u origin feature/your-feature-name
```

**Create PR with GitHub CLI:**
```bash
gh pr create --title "Brief Title" --body "$(cat <<'EOF'
## Summary
- Bullet point summary
- Of main changes

## Changes
- Detailed change 1
- Detailed change 2

## Testing
- [ ] Tested with swift run
- [ ] Tested with swift build -c release
- [ ] Tested installed .app behavior
- [ ] Updated documentation

EOF
)"
```

**After PR is created:**
- GitHub will assign a PR number (e.g., #30)
- Add PR reference to your entry in `CHANGELOG.md`
- Commit and push: `git commit -am "Add PR #30 to CHANGELOG" && git push`

### 5. After PR Merge

```bash
git checkout main
git pull
```

## Commit Message Format

Use this format for consistency:

```
Type: Brief description (50 chars or less)

Detailed explanation of what changed and why. Wrap at 72 characters.
Include any relevant context or decisions made.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Your Name <your.email@example.com>
```

**Types:**
- `Feature:` - New functionality
- `Enhancement:` - Improvement to existing feature
- `Fix:` - Bug fix
- `Docs:` - Documentation changes
- `Refactor:` - Code restructuring without behavior change
- `Test:` - Adding or updating tests

## Avoiding Merge Conflicts

1. **Check `status:in-progress` issues** before starting work
2. **Update your branch regularly** with main:
   ```bash
   git checkout main
   git pull
   git checkout your-branch
   git merge main
   ```
3. **Keep PRs focused** - One feature/bug per PR
4. **Communicate** - Use draft PRs to show work in progress

## Testing Requirements

Before submitting a PR, ensure:
- [ ] App builds without errors: `swift build -c release`
- [ ] App runs correctly: `swift run`
- [ ] Tested installed behavior if UI/permissions changes: `./build-app.sh --install`
- [ ] No console errors or warnings
- [ ] Documentation updated (README, CHANGELOG, GitHub issues status)

## Code Style

- Follow Swift best practices and conventions
- Use clear, descriptive variable and function names
- Add comments for complex logic
- Keep functions focused and single-purpose
- Use `@MainActor` for UI components

## Questions?

- Review existing PRs for examples
- Check `DEVELOPMENT.md` for architecture details
- Check `CLAUDE.md` for AI collaboration workflow
- Open an issue for discussion

Thank you for contributing!
