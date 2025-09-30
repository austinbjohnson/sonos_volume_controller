# Development Workflow

## Quick Testing (Development)

When making changes and testing, use `swift run`:

```bash
# Kill any running instance first
pkill SonosVolumeController

# Run your dev version
swift run
```

This runs the app directly from your development directory without needing to build the .app bundle or install anywhere. Press `Ctrl+C` to stop it when done testing.

**Benefits:**
- Fast - no build/install step needed
- Changes compile automatically
- Easy to iterate quickly

## Installing to /Applications (Production)

When you're ready to use your changes as your daily driver app, install to /Applications:

```bash
./build-app.sh --install
```

This will:
1. Build the .app bundle
2. Kill any running instance
3. Copy to /Applications
4. Launch the installed version

**You MUST install to /Applications if you want:**
- App to run on login (the "Run at Login" feature)
- App to run without the terminal
- A permanent version that's not tied to development

## Typical Development Cycle

1. **Make code changes** in your editor
2. **Test with `swift run`** - repeat as needed
3. **Commit your changes** to git
4. **Create/merge PR** when satisfied
5. **Install to /Applications** when ready to use permanently: `./build-app.sh --install`

## Note: You Cannot Run Both Versions Simultaneously

The development version (via `swift run`) and installed version (in /Applications) will conflict because they both:
- Create a menu bar icon
- Listen for the same hotkeys
- Monitor the same audio device
- Control the same Sonos speakers

Always kill one before running the other with `pkill SonosVolumeController`.

## Building Without Installing

If you just want to build the .app bundle without installing:

```bash
./build-app.sh
```

The .app will be created in your project directory as `SonosVolumeController.app`.