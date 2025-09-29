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
    NSTextAlignmentCenter, NSBorderlessWindowMask, NSTitledWindowMask,
    NSClosableWindowMask, NSMiniaturizableWindowMask, NSResizableWindowMask,
    NSTabView, NSTabViewItem, NSButton, NSSlider, NSComboBox, NSPopUpButton,
    NSBox, NSBoxSeparator
)
from Foundation import NSTimer, NSUserDefaults, NSMakePoint, NSMakeSize
from AppKit import NSApp, NSApplication
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


class PreferencesWindow:
    """Preferences window for Sonos Volume Controller"""

    def __init__(self, app):
        self.app = app
        self.window = None
        self.is_recording_hotkey = False
        self.recorded_keys = []

    def show(self):
        """Show the preferences window"""
        if self.window:
            self.window.makeKeyAndOrderFront_(None)
            NSApp.activateIgnoringOtherApps_(True)
            return

        # Create window
        window_rect = NSMakeRect(0, 0, 600, 500)
        style_mask = NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask

        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            window_rect,
            style_mask,
            NSBackingStoreBuffered,
            False
        )

        self.window.setTitle_("Preferences")
        self.window.center()

        # Create tab view
        tab_view = NSTabView.alloc().initWithFrame_(NSMakeRect(20, 20, 560, 430))

        # General Tab
        general_tab = NSTabViewItem.alloc().initWithIdentifier_("general")
        general_tab.setLabel_("General")
        general_view = self.create_general_tab()
        general_tab.setView_(general_view)
        tab_view.addTabViewItem_(general_tab)

        # Audio Devices Tab
        audio_tab = NSTabViewItem.alloc().initWithIdentifier_("audio")
        audio_tab.setLabel_("Audio Devices")
        audio_view = self.create_audio_tab()
        audio_tab.setView_(audio_view)
        tab_view.addTabViewItem_(audio_tab)

        # Sonos Tab
        sonos_tab = NSTabViewItem.alloc().initWithIdentifier_("sonos")
        sonos_tab.setLabel_("Sonos")
        sonos_view = self.create_sonos_tab()
        sonos_tab.setView_(sonos_view)
        tab_view.addTabViewItem_(sonos_tab)

        self.window.contentView().addSubview_(tab_view)

        # Show window
        self.window.makeKeyAndOrderFront_(None)
        NSApp.activateIgnoringOtherApps_(True)

    def create_general_tab(self):
        """Create the General preferences tab"""
        view = NSBox.alloc().initWithFrame_(NSMakeRect(0, 0, 560, 400))
        view.setBoxType_(0)  # NSBoxPrimary
        view.setBorderType_(0)  # NSNoBorder

        y_pos = 350

        # Enable/Disable checkbox
        enable_checkbox = NSButton.alloc().initWithFrame_(NSMakeRect(20, y_pos, 300, 25))
        enable_checkbox.setButtonType_(3)  # NSSwitchButton
        enable_checkbox.setTitle_("Enable Sonos Control")
        enable_checkbox.setState_(1 if self.app.enabled else 0)
        enable_checkbox.setTarget_(self)
        enable_checkbox.setAction_(objc.selector(self.toggle_enabled_, signature=b'v@:@'))
        view.addSubview_(enable_checkbox)
        self.enable_checkbox = enable_checkbox

        y_pos -= 50

        # Volume Step label
        volume_label = NSTextField.alloc().initWithFrame_(NSMakeRect(20, y_pos, 200, 20))
        volume_label.setStringValue_("Volume Step Size:")
        volume_label.setBezeled_(False)
        volume_label.setDrawsBackground_(False)
        volume_label.setEditable_(False)
        volume_label.setSelectable_(False)
        view.addSubview_(volume_label)

        y_pos -= 30

        # Volume Step slider
        volume_slider = NSSlider.alloc().initWithFrame_(NSMakeRect(20, y_pos, 300, 25))
        volume_slider.setMinValue_(1)
        volume_slider.setMaxValue_(20)
        volume_slider.setIntValue_(self.app.volume_step)
        volume_slider.setTarget_(self)
        volume_slider.setAction_(objc.selector(self.volume_step_changed_, signature=b'v@:@'))
        view.addSubview_(volume_slider)
        self.volume_slider = volume_slider

        # Volume step value label
        volume_value_label = NSTextField.alloc().initWithFrame_(NSMakeRect(330, y_pos, 50, 20))
        volume_value_label.setStringValue_(f"{self.app.volume_step}%")
        volume_value_label.setBezeled_(False)
        volume_value_label.setDrawsBackground_(False)
        volume_value_label.setEditable_(False)
        volume_value_label.setSelectable_(False)
        view.addSubview_(volume_value_label)
        self.volume_value_label = volume_value_label

        y_pos -= 50

        # Hotkey section
        hotkey_label = NSTextField.alloc().initWithFrame_(NSMakeRect(20, y_pos, 200, 20))
        hotkey_label.setStringValue_("Volume Control Hotkeys:")
        hotkey_label.setBezeled_(False)
        hotkey_label.setDrawsBackground_(False)
        hotkey_label.setEditable_(False)
        hotkey_label.setSelectable_(False)
        view.addSubview_(hotkey_label)

        y_pos -= 30

        # Current hotkey display
        hotkey_text = NSTextField.alloc().initWithFrame_(NSMakeRect(20, y_pos, 300, 24))
        hotkey_text.setStringValue_(self.get_current_hotkey_display())
        hotkey_text.setBezeled_(True)
        hotkey_text.setDrawsBackground_(True)
        hotkey_text.setEditable_(False)
        hotkey_text.setSelectable_(False)
        view.addSubview_(hotkey_text)
        self.hotkey_text = hotkey_text

        # Record button
        record_button = NSButton.alloc().initWithFrame_(NSMakeRect(330, y_pos - 2, 120, 28))
        record_button.setTitle_("Record Hotkeys")
        record_button.setBezelStyle_(1)  # NSRoundedBezelStyle
        record_button.setTarget_(self)
        record_button.setAction_(objc.selector(self.record_hotkey_, signature=b'v@:@'))
        view.addSubview_(record_button)
        self.record_button = record_button

        y_pos -= 40

        # Info label
        info_label = NSTextField.alloc().initWithFrame_(NSMakeRect(20, y_pos, 500, 40))
        info_label.setStringValue_("Click 'Record Hotkeys' then press two keys:\nFirst for volume down, then for volume up.")
        info_label.setBezeled_(False)
        info_label.setDrawsBackground_(False)
        info_label.setEditable_(False)
        info_label.setSelectable_(False)
        view.addSubview_(info_label)

        return view

    def create_audio_tab(self):
        """Create the Audio Devices preferences tab"""
        view = NSBox.alloc().initWithFrame_(NSMakeRect(0, 0, 560, 400))
        view.setBoxType_(0)
        view.setBorderType_(0)

        y_pos = 350

        # Trigger Device label
        trigger_label = NSTextField.alloc().initWithFrame_(NSMakeRect(20, y_pos, 400, 20))
        trigger_label.setStringValue_("Trigger Audio Device (activates Sonos control):")
        trigger_label.setBezeled_(False)
        trigger_label.setDrawsBackground_(False)
        trigger_label.setEditable_(False)
        trigger_label.setSelectable_(False)
        view.addSubview_(trigger_label)

        y_pos -= 30

        # Audio device dropdown
        audio_dropdown = NSPopUpButton.alloc().initWithFrame_(NSMakeRect(20, y_pos, 400, 26))
        audio_devices = self.get_all_audio_devices()
        for device in audio_devices:
            audio_dropdown.addItemWithTitle_(device)

        # Select current trigger device
        if self.app.trigger_device in audio_devices:
            audio_dropdown.selectItemWithTitle_(self.app.trigger_device)

        audio_dropdown.setTarget_(self)
        audio_dropdown.setAction_(objc.selector(self.trigger_device_changed_, signature=b'v@:@'))
        view.addSubview_(audio_dropdown)
        self.audio_dropdown = audio_dropdown

        y_pos -= 50

        # Current device label
        current_label = NSTextField.alloc().initWithFrame_(NSMakeRect(20, y_pos, 400, 20))
        current_label.setStringValue_(f"Current Active Device: {self.app.current_device}")
        current_label.setBezeled_(False)
        current_label.setDrawsBackground_(False)
        current_label.setEditable_(False)
        current_label.setSelectable_(False)
        view.addSubview_(current_label)
        self.current_device_label = current_label

        y_pos -= 30

        # Status indicator
        status_text = "✅ Active (Sonos control enabled)" if self.app.should_intercept() else "⚪ Inactive (using different device or disabled)"
        status_label = NSTextField.alloc().initWithFrame_(NSMakeRect(20, y_pos, 400, 20))
        status_label.setStringValue_(status_text)
        status_label.setBezeled_(False)
        status_label.setDrawsBackground_(False)
        status_label.setEditable_(False)
        status_label.setSelectable_(False)
        view.addSubview_(status_label)
        self.status_label = status_label

        return view

    def create_sonos_tab(self):
        """Create the Sonos preferences tab"""
        view = NSBox.alloc().initWithFrame_(NSMakeRect(0, 0, 560, 400))
        view.setBoxType_(0)
        view.setBorderType_(0)

        y_pos = 350

        # Default speaker label
        default_label = NSTextField.alloc().initWithFrame_(NSMakeRect(20, y_pos, 400, 20))
        default_label.setStringValue_("Default Sonos Speaker (auto-select on startup):")
        default_label.setBezeled_(False)
        default_label.setDrawsBackground_(False)
        default_label.setEditable_(False)
        default_label.setSelectable_(False)
        view.addSubview_(default_label)

        y_pos -= 30

        # Sonos speaker dropdown
        sonos_dropdown = NSPopUpButton.alloc().initWithFrame_(NSMakeRect(20, y_pos, 400, 26))
        sonos_dropdown.addItemWithTitle_("(None - Manual Selection)")

        for device in self.app.sonos_devices:
            sonos_dropdown.addItemWithTitle_(device.player_name)

        # Select current default speaker
        default_speaker = self.app.defaults.stringForKey_('default_sonos_speaker') or ""
        if default_speaker:
            sonos_dropdown.selectItemWithTitle_(default_speaker)

        sonos_dropdown.setTarget_(self)
        sonos_dropdown.setAction_(objc.selector(self.default_speaker_changed_, signature=b'v@:@'))
        view.addSubview_(sonos_dropdown)
        self.sonos_dropdown = sonos_dropdown

        y_pos -= 40

        # Refresh button
        refresh_button = NSButton.alloc().initWithFrame_(NSMakeRect(20, y_pos, 150, 28))
        refresh_button.setTitle_("Refresh Devices")
        refresh_button.setBezelStyle_(1)
        refresh_button.setTarget_(self)
        refresh_button.setAction_(objc.selector(self.refresh_sonos_, signature=b'v@:@'))
        view.addSubview_(refresh_button)

        y_pos -= 50

        # Current speaker
        current_speaker = self.app.selected_sonos.player_name if self.app.selected_sonos else "(None)"
        current_speaker_label = NSTextField.alloc().initWithFrame_(NSMakeRect(20, y_pos, 400, 20))
        current_speaker_label.setStringValue_(f"Currently Controlling: {current_speaker}")
        current_speaker_label.setBezeled_(False)
        current_speaker_label.setDrawsBackground_(False)
        current_speaker_label.setEditable_(False)
        current_speaker_label.setSelectable_(False)
        view.addSubview_(current_speaker_label)
        self.current_speaker_label = current_speaker_label

        y_pos -= 30

        # Device count
        device_count_label = NSTextField.alloc().initWithFrame_(NSMakeRect(20, y_pos, 400, 20))
        device_count_label.setStringValue_(f"Discovered Devices: {len(self.app.sonos_devices)}")
        device_count_label.setBezeled_(False)
        device_count_label.setDrawsBackground_(False)
        device_count_label.setEditable_(False)
        device_count_label.setSelectable_(False)
        view.addSubview_(device_count_label)
        self.device_count_label = device_count_label

        return view

    def get_current_hotkey_display(self):
        """Get display string for current hotkeys"""
        down_key = self.app.defaults.stringForKey_('hotkey_down') or "f11"
        up_key = self.app.defaults.stringForKey_('hotkey_up') or "f12"
        return f"Down: {down_key.upper()}  |  Up: {up_key.upper()}"

    def get_all_audio_devices(self):
        """Get list of all available audio output devices"""
        try:
            result = subprocess.run(
                ["system_profiler", "SPAudioDataType", "-json"],
                capture_output=True,
                text=True,
                timeout=5
            )
            data = json.loads(result.stdout)

            devices = []
            for item in data.get("SPAudioDataType", [{}])[0].get("_items", []):
                name = item.get("_name")
                if name and name not in devices:
                    devices.append(name)

            return sorted(devices) if devices else ["No devices found"]
        except Exception as e:
            print(f"Error getting audio devices: {e}")
            return ["Error loading devices"]

    # Callback methods
    @objc.python_method
    def toggle_enabled_(self, sender):
        """Toggle enabled state"""
        self.app.enabled = sender.state() == 1
        self.app.defaults.setObject_forKey_(self.app.enabled, 'enabled')
        self.app.defaults.synchronize()

        # Update menu
        if "Enable Sonos Control" in self.app.menu:
            self.app.menu["Enable Sonos Control"].state = 1 if self.app.enabled else 0

        print(f"Sonos control {'enabled' if self.app.enabled else 'disabled'}")

    @objc.python_method
    def volume_step_changed_(self, sender):
        """Volume step slider changed"""
        new_value = sender.intValue()
        self.app.volume_step = new_value
        self.app.defaults.setInteger_forKey_(new_value, 'volume_step')
        self.app.defaults.synchronize()
        self.volume_value_label.setStringValue_(f"{new_value}%")
        print(f"Volume step changed to: {new_value}%")

    @objc.python_method
    def trigger_device_changed_(self, sender):
        """Trigger device dropdown changed"""
        selected = sender.titleOfSelectedItem()
        self.app.trigger_device = selected
        self.app.defaults.setObject_forKey_(selected, 'trigger_device')
        self.app.defaults.synchronize()
        print(f"Trigger device changed to: {selected}")

    @objc.python_method
    def default_speaker_changed_(self, sender):
        """Default speaker dropdown changed"""
        selected = sender.titleOfSelectedItem()
        if selected == "(None - Manual Selection)":
            self.app.defaults.removeObjectForKey_('default_sonos_speaker')
            print("Default speaker cleared")
        else:
            self.app.defaults.setObject_forKey_(selected, 'default_sonos_speaker')
            print(f"Default speaker set to: {selected}")
        self.app.defaults.synchronize()

    @objc.python_method
    def refresh_sonos_(self, sender):
        """Refresh Sonos devices"""
        self.app.refresh_sonos_devices(None)
        # Update UI after a delay
        def update_ui():
            time.sleep(3)
            if self.sonos_dropdown:
                self.sonos_dropdown.removeAllItems()
                self.sonos_dropdown.addItemWithTitle_("(None - Manual Selection)")
                for device in self.app.sonos_devices:
                    self.sonos_dropdown.addItemWithTitle_(device.player_name)
                self.device_count_label.setStringValue_(f"Discovered Devices: {len(self.app.sonos_devices)}")
        Thread(target=update_ui, daemon=True).start()

    @objc.python_method
    def record_hotkey_(self, sender):
        """Start recording hotkeys"""
        if self.is_recording_hotkey:
            return

        self.is_recording_hotkey = True
        self.recorded_keys = []
        self.record_button.setTitle_("Recording...")
        self.record_button.setEnabled_(False)
        self.hotkey_text.setStringValue_("Press key for Volume Down...")

        def on_press(key):
            try:
                key_str = key.char if hasattr(key, 'char') else str(key).replace('Key.', '')
            except:
                key_str = str(key).replace('Key.', '')

            self.recorded_keys.append(key_str)

            if len(self.recorded_keys) == 1:
                self.hotkey_text.setStringValue_(f"Down: {key_str.upper()} | Now press key for Volume Up...")
            elif len(self.recorded_keys) == 2:
                self.hotkey_text.setStringValue_(f"Down: {self.recorded_keys[0].upper()}  |  Up: {self.recorded_keys[1].upper()}")
                self.finish_recording()
                return False  # Stop listener

        # Start keyboard listener
        listener = keyboard.Listener(on_press=on_press)
        listener.start()

    @objc.python_method
    def finish_recording(self):
        """Finish recording hotkeys"""
        self.is_recording_hotkey = False
        self.record_button.setTitle_("Record Hotkeys")
        self.record_button.setEnabled_(True)

        if len(self.recorded_keys) == 2:
            # Save hotkeys
            self.app.defaults.setObject_forKey_(self.recorded_keys[0], 'hotkey_down')
            self.app.defaults.setObject_forKey_(self.recorded_keys[1], 'hotkey_up')
            self.app.defaults.synchronize()

            # Restart hotkey listener with new keys
            self.app.restart_hotkey_listener()

            print(f"Hotkeys updated: Down={self.recorded_keys[0]}, Up={self.recorded_keys[1]}")

            rumps.notification(
                "Hotkeys Updated",
                None,
                f"Volume Down: {self.recorded_keys[0].upper()}, Volume Up: {self.recorded_keys[1].upper()}",
                sound=False
            )


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
        self.default_sonos_speaker = self.defaults.stringForKey_('default_sonos_speaker') or ""
        self.selected_sonos = None
        self.sonos_devices = []

        # Load volume step from preferences (default 5%)
        saved_volume_step = self.defaults.integerForKey_('volume_step')
        self.volume_step = saved_volume_step if saved_volume_step > 0 else 5

        # Initialize preferences window
        self.preferences_window = PreferencesWindow(self)

        # Current audio device
        self.current_device = self.get_current_audio_device()
        self.current_volume = 0

        # Menu items
        self.volume_item = rumps.MenuItem("Volume: --", callback=None)
        self.device_item = rumps.MenuItem(f"Current Device: {self.current_device}", callback=None)

        # Get current hotkey display
        hotkey_down = self.defaults.stringForKey_('hotkey_down') or "f11"
        hotkey_up = self.defaults.stringForKey_('hotkey_up') or "f12"

        self.menu = [
            self.volume_item,
            self.device_item,
            rumps.separator,
            rumps.MenuItem("Enable Sonos Control", callback=self.toggle_enabled),
            rumps.separator,
            f"Hotkeys: {hotkey_down.upper()} (Down) / {hotkey_up.upper()} (Up)",
            rumps.separator,
            "Sonos Speakers:",
            rumps.MenuItem("Refresh Devices", callback=self.refresh_sonos_devices),
            rumps.separator,
            rumps.MenuItem("Preferences...", callback=self.show_preferences),
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
        # Get custom hotkeys from preferences
        hotkey_down = self.defaults.stringForKey_('hotkey_down') or "f11"
        hotkey_up = self.defaults.stringForKey_('hotkey_up') or "f12"

        def on_activate_volume_up():
            if self.should_intercept():
                print(f"Hotkey: {hotkey_up.upper()} - Controlling Sonos")
                self.change_volume(self.volume_step)
            else:
                print(f"Hotkey: {hotkey_up.upper()} - Not intercepting (wrong device or disabled)")

        def on_activate_volume_down():
            if self.should_intercept():
                print(f"Hotkey: {hotkey_down.upper()} - Controlling Sonos")
                self.change_volume(-self.volume_step)
            else:
                print(f"Hotkey: {hotkey_down.upper()} - Not intercepting (wrong device or disabled)")

        # Register hotkeys with custom keys
        self.hotkey_listener = keyboard.GlobalHotKeys({
            f'<{hotkey_down}>': on_activate_volume_down,
            f'<{hotkey_up}>': on_activate_volume_up,
        })
        self.hotkey_listener.start()
        print(f"Hotkey listener started: {hotkey_down.upper()} (down) / {hotkey_up.upper()} (up) to control Sonos")

    def restart_hotkey_listener(self):
        """Restart hotkey listener with new keys"""
        if hasattr(self, 'hotkey_listener'):
            self.hotkey_listener.stop()
        self.start_volume_key_listener()

    def show_preferences(self, sender):
        """Show preferences window"""
        self.preferences_window.show()

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

                    # Auto-select default speaker (highest priority) or last selected speaker
                    speaker_to_select = self.default_sonos_speaker or self.last_selected_speaker

                    if speaker_to_select:
                        for device in self.sonos_devices:
                            if device.player_name == speaker_to_select:
                                self.selected_sonos = device
                                self.update_menu_bar_title()
                                selection_type = "default" if speaker_to_select == self.default_sonos_speaker else "last"
                                print(f"Auto-selected {selection_type} speaker: {device.player_name}")
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

        # List of permanent menu items that should not be removed
        permanent_items = ["Enable Sonos Control", "Sonos Speakers:", "Refresh Devices", "Preferences...", "Quit"]

        for key in self.menu.keys():
            # Skip volume/device items and permanent items
            if key.startswith("Volume:") or key.startswith("Current Device:") or key.startswith("Hotkeys:"):
                continue
            if key in permanent_items:
                continue

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



if __name__ == "__main__":
    print("Starting Sonos Volume Controller...")
    print("⚠️  You may need to grant accessibility permissions in System Settings > Privacy & Security > Accessibility")
    app = SonosVolumeController()
    app.run()