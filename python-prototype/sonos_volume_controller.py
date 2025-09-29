#!/usr/bin/env python3
"""
Sonos Volume Controller for macOS
Intercepts volume keys and controls Sonos speakers when specific audio output is active
"""

import sys
import subprocess
import json
from threading import Thread, Event
import time
from Cocoa import (
    NSWindow, NSFloatingWindowLevel, NSBackingStoreBuffered,
    NSScreen, NSTextField, NSMakeRect, NSColor, NSFont,
    NSTextAlignmentCenter, NSBorderlessWindowMask
)
from Foundation import NSTimer, NSUserDefaults
from AppKit import NSApp
import objc

try:
    import rumps
    import soco
    from soco.discovery import discover
    from pynput import keyboard
except ImportError as e:
    print(f"Missing dependencies. Install with:")
    print(f"pip3 install rumps soco pynput")
    sys.exit(1)


class SonosVolumeController(rumps.App):
    def __init__(self):
        super(SonosVolumeController, self).__init__(
            "♫",
            icon=None
        )

        # Settings (using UserDefaults to persist)
        self.defaults = NSUserDefaults.standardUserDefaults()
        self.enabled = self.defaults.objectForKey_('enabled')
        if self.enabled is None:
            self.enabled = True
        self.trigger_device = self.defaults.stringForKey_('trigger_device') or "DELL U2723QE"
        self.last_selected_speaker = self.defaults.stringForKey_('last_selected_speaker')
        self.selected_sonos = None
        self.sonos_devices = []
        self.volume_step = 5

        # Current audio device
        self.current_device = self.get_current_audio_device()
        self.current_volume = 0

        # Menu items
        self.volume_item = rumps.MenuItem("Volume: --", callback=None)
        self.device_item = rumps.MenuItem(f"Current Device: {self.current_device}", callback=None)

        self.menu = [
            self.volume_item,
            rumps.separator,
            rumps.MenuItem("Enable Sonos Control", callback=self.toggle_enabled),
            rumps.separator,
            "Hotkeys: Fn+F11 (Down) / Fn+F12 (Up)",
            rumps.separator,
            "Sonos Speakers:",
            rumps.MenuItem("Refresh Devices", callback=self.refresh_sonos_devices),
            rumps.separator,
            rumps.MenuItem("Configure Trigger Device", callback=self.configure_trigger),
            self.device_item,
        ]

        self.menu["Enable Sonos Control"].state = 1 if self.enabled else 0

        # Start audio device monitoring
        self.monitor_stop_event = Event()
        self.monitor_thread = Thread(target=self.monitor_audio_device, daemon=True)
        self.monitor_thread.start()

        # Start volume key listener
        self.start_volume_key_listener()

        # Discover Sonos devices
        self.refresh_sonos_devices(None)

    def get_current_audio_device(self):
        """Get the current default audio output device"""
        try:
            result = subprocess.run(
                ["system_profiler", "SPAudioDataType", "-json"],
                capture_output=True,
                text=True,
                timeout=5
            )
            data = json.loads(result.stdout)

            # Find default output device
            for device in data.get("SPAudioDataType", [{}])[0].get("_items", []):
                if device.get("coreaudio_default_audio_output_device") == "spaudio_yes":
                    return device.get("_name", "Unknown")

            return "Unknown"
        except Exception as e:
            print(f"Error getting audio device: {e}")
            return "Unknown"

    def monitor_audio_device(self):
        """Monitor for changes in audio output device"""
        while not self.monitor_stop_event.is_set():
            new_device = self.get_current_audio_device()
            if new_device != self.current_device:
                self.current_device = new_device
                print(f"Audio device changed to: {self.current_device}")
                # Update menu
                rumps.notification(
                    "Audio Device Changed",
                    None,
                    f"Now using: {self.current_device}"
                )
            time.sleep(2)

    def should_intercept(self):
        """Check if we should intercept volume keys"""
        return self.enabled and self.current_device == self.trigger_device and self.selected_sonos

    def start_volume_key_listener(self):
        """Start listening for hotkey combinations"""
        def on_activate_volume_up():
            if self.should_intercept():
                print("Hotkey: Fn+F12 - Controlling Sonos")
                self.change_volume(self.volume_step)
            else:
                print("Hotkey: Fn+F12 - Not intercepting (wrong device or disabled)")

        def on_activate_volume_down():
            if self.should_intercept():
                print("Hotkey: Fn+F11 - Controlling Sonos")
                self.change_volume(-self.volume_step)
            else:
                print("Hotkey: Fn+F11 - Not intercepting (wrong device or disabled)")

        # Register hotkeys: Fn+F11/F12
        # Note: F11/F12 without fn modifier since fn is handled by the keyboard itself
        self.hotkey_listener = keyboard.GlobalHotKeys({
            '<f11>': on_activate_volume_down,
            '<f12>': on_activate_volume_up,
        })
        self.hotkey_listener.start()
        print("Hotkey listener started: Fn+F11 (down) / Fn+F12 (up) to control Sonos")

    def create_volume_bar(self, volume):
        """Create a visual volume bar"""
        bar_length = 20
        filled = int(bar_length * volume / 100)
        empty = bar_length - filled
        bar = "█" * filled + "░" * empty
        return f"{bar} {volume}%"

    def update_menu_bar_title(self):
        """Update menu bar title with speaker name and volume"""
        if self.selected_sonos:
            speaker_name = self.selected_sonos.player_name
            # Shorten long names
            if len(speaker_name) > 8:
                speaker_name = speaker_name[:8] + "…"
            self.title = f"♫ {speaker_name} {self.current_volume}"
        else:
            self.title = "♫"

    def show_volume_hud(self, volume):
        """Show on-screen volume display (HUD)"""
        try:
            # Close existing HUD window if any
            if hasattr(self, 'hud_window') and self.hud_window:
                self.hud_window.orderOut_(None)
                self.hud_window = None

            # Get screen dimensions
            screen = NSScreen.mainScreen()
            screen_frame = screen.frame()

            # Window dimensions
            width = 300
            height = 80
            x = (screen_frame.size.width - width) / 2
            y = screen_frame.size.height - 150  # Near top of screen

            # Create window
            self.hud_window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
                NSMakeRect(x, y, width, height),
                NSBorderlessWindowMask,
                NSBackingStoreBuffered,
                False
            )

            # Configure window
            self.hud_window.setLevel_(NSFloatingWindowLevel)
            self.hud_window.setOpaque_(False)
            self.hud_window.setBackgroundColor_(NSColor.colorWithCalibratedWhite_alpha_(0.1, 0.85))
            self.hud_window.setHasShadow_(True)

            # Create volume text
            volume_bar = self.create_volume_bar(volume)
            text_field = NSTextField.alloc().initWithFrame_(NSMakeRect(10, 10, width - 20, height - 20))
            text_field.setStringValue_(f"♫ Sonos\n{volume_bar}")
            text_field.setFont_(NSFont.systemFontOfSize_(18))
            text_field.setTextColor_(NSColor.whiteColor())
            text_field.setBackgroundColor_(NSColor.clearColor())
            text_field.setBezeled_(False)
            text_field.setEditable_(False)
            text_field.setAlignment_(NSTextAlignmentCenter)

            # Add to window
            self.hud_window.contentView().addSubview_(text_field)

            # Show window
            self.hud_window.makeKeyAndOrderFront_(None)

            # Auto-hide after 1.5 seconds using timer (main thread safe)
            def hide_window(timer):
                if self.hud_window:
                    self.hud_window.orderOut_(None)
                    self.hud_window = None

            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                1.5, self, 'hideHUD:', None, False
            )

        except Exception as e:
            print(f"Error showing HUD: {e}")

    def hideHUD_(self, timer):
        """Timer callback to hide HUD"""
        if hasattr(self, 'hud_window') and self.hud_window:
            self.hud_window.orderOut_(None)
            self.hud_window = None

    def change_volume(self, delta):
        """Change Sonos volume by delta"""
        if not self.selected_sonos:
            return

        try:
            current_volume = self.selected_sonos.volume
            new_volume = max(0, min(100, current_volume + delta))
            self.selected_sonos.volume = new_volume
            self.current_volume = new_volume
            print(f"Sonos volume: {current_volume} -> {new_volume}")

            # Update menu bar volume display
            volume_bar = self.create_volume_bar(new_volume)
            self.volume_item.title = f"Volume: {volume_bar}"

            # Update menu bar title with speaker name and volume
            self.update_menu_bar_title()

        except Exception as e:
            print(f"Error changing volume: {e}")

    def showVolumeHUDOnMainThread_(self, volume):
        """Wrapper to call show_volume_hud on main thread"""
        self.show_volume_hud(volume)

    def toggle_mute(self):
        """Toggle Sonos mute"""
        if not self.selected_sonos:
            return

        try:
            current_mute = self.selected_sonos.mute
            self.selected_sonos.mute = not current_mute
            print(f"Sonos mute: {not current_mute}")
        except Exception as e:
            print(f"Error toggling mute: {e}")

    def toggle_enabled(self, sender):
        """Toggle enable/disable"""
        self.enabled = not self.enabled
        sender.state = 1 if self.enabled else 0
        self.defaults.setObject_forKey_(self.enabled, 'enabled')
        self.defaults.synchronize()
        print(f"Sonos control {'enabled' if self.enabled else 'disabled'}")

    def refresh_sonos_devices(self, sender):
        """Discover Sonos devices on network"""
        rumps.notification(
            "Discovering Sonos Devices",
            None,
            "Searching network...",
            sound=False
        )

        def discover_devices():
            try:
                print("Discovering Sonos devices...")
                devices = discover(timeout=3)

                if devices:
                    # Sort devices alphabetically by name
                    self.sonos_devices = sorted(list(devices), key=lambda d: d.player_name)
                    print(f"Found {len(self.sonos_devices)} Sonos devices")
                    for device in self.sonos_devices:
                        print(f"  - {device.player_name}")

                    # Update menu
                    self.update_sonos_menu()

                    # Auto-select last selected speaker if it exists
                    if self.last_selected_speaker:
                        for device in self.sonos_devices:
                            if device.player_name == self.last_selected_speaker:
                                self.selected_sonos = device
                                self.update_menu_bar_title()
                                print(f"Auto-selected last speaker: {device.player_name}")
                                # Update the volume display
                                try:
                                    current_volume = device.volume
                                    self.current_volume = current_volume
                                    volume_bar = self.create_volume_bar(current_volume)
                                    self.volume_item.title = f"Volume: {volume_bar}"
                                except Exception as e:
                                    print(f"Error getting volume: {e}")
                                break

                    rumps.notification(
                        "Sonos Devices Found",
                        None,
                        f"Found {len(self.sonos_devices)} device(s)",
                        sound=False
                    )
                else:
                    print("No Sonos devices found")
                    rumps.notification(
                        "No Sonos Devices",
                        None,
                        "No devices found on network",
                        sound=False
                    )
            except Exception as e:
                print(f"Error discovering devices: {e}")
                rumps.notification(
                    "Discovery Error",
                    None,
                    str(e),
                    sound=False
                )

        # Run discovery in background
        Thread(target=discover_devices, daemon=True).start()

    def update_sonos_menu(self):
        """Update the Sonos speaker menu"""
        # Remove old device menu items (ones that start with speaker names, not spaces)
        items_to_remove = []
        for key in self.menu.keys():
            # Remove items that are between "Sonos Speakers:" and "Refresh Devices"
            if key not in ["Volume: --", "Current Device: Unknown", "Enable Sonos Control",
                          "Hotkeys: Fn+F11 (Down) / Fn+F12 (Up)", "Sonos Speakers:",
                          "Refresh Devices", "Configure Trigger Device", "Quit"]:
                # Check if it's a speaker item (not a separator or static menu item)
                try:
                    if self.menu[key] and hasattr(self.menu[key], 'title'):
                        items_to_remove.append(key)
                except:
                    pass

        for item in items_to_remove:
            del self.menu[item]

        # Add speaker items after "Sonos Speakers:" header
        for device in self.sonos_devices:
            try:
                name = device.player_name
                # No indentation - just the speaker name
                item = rumps.MenuItem(
                    name,
                    callback=lambda sender, dev=device: self.select_sonos(sender, dev)
                )
                if self.selected_sonos and self.selected_sonos.player_name == name:
                    item.state = 1
                else:
                    item.state = 0

                # Insert before "Refresh Devices"
                menu_keys = list(self.menu.keys())
                refresh_index = menu_keys.index("Refresh Devices")
                self.menu.insert_before("Refresh Devices", item)
            except Exception as e:
                print(f"Error adding device to menu: {e}")

    def select_sonos(self, sender, device):
        """Select a Sonos device"""
        print(f"select_sonos called with device: {device}")
        self.selected_sonos = device
        print(f"Selected Sonos: {device.player_name}")

        # Save selection to preferences
        self.last_selected_speaker = device.player_name
        self.defaults.setObject_forKey_(device.player_name, 'last_selected_speaker')
        self.defaults.synchronize()
        print(f"Saved last selected speaker: {device.player_name}")

        # Get current volume and update display
        try:
            current_volume = device.volume
            self.current_volume = current_volume
            volume_bar = self.create_volume_bar(current_volume)
            self.volume_item.title = f"Volume: {volume_bar}"
            print(f"Current volume: {current_volume}%")
        except Exception as e:
            print(f"Error getting volume: {e}")

        # Update menu bar title
        self.update_menu_bar_title()

        # Update menu checkmarks - uncheck all speakers
        for device in self.sonos_devices:
            try:
                if device.player_name in self.menu:
                    self.menu[device.player_name].state = 0
            except:
                pass
        # Check the selected one
        sender.state = 1

        rumps.notification(
            "Sonos Device Selected",
            None,
            f"Now controlling: {device.player_name}",
            sound=False
        )

    def configure_trigger(self, sender):
        """Configure trigger device"""
        response = rumps.Window(
            message=f"Current trigger device: {self.trigger_device}\n\nEnter the audio device name that should trigger Sonos control:",
            title="Configure Trigger Device",
            default_text=self.trigger_device,
            ok="Save",
            cancel="Cancel",
            dimensions=(320, 100)
        ).run()

        if response.clicked and response.text.strip():
            self.trigger_device = response.text.strip()
            print(f"Trigger device set to: {self.trigger_device}")
            rumps.notification(
                "Trigger Device Updated",
                None,
                f"Set to: {self.trigger_device}",
                sound=False
            )


if __name__ == "__main__":
    print("Starting Sonos Volume Controller...")
    print("⚠️  You may need to grant accessibility permissions in System Settings > Privacy & Security > Accessibility")
    app = SonosVolumeController()
    app.run()