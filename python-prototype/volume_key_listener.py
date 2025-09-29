#!/usr/bin/env python3
"""
Low-level volume key listener using Quartz Event Taps
"""

import Quartz
from Cocoa import NSEvent, NSSystemDefined
from threading import Thread


class VolumeKeyListener:
    """Listen for volume key presses using Quartz event taps"""

    # NX_KEYTYPE_SOUND_UP = 0
    # NX_KEYTYPE_SOUND_DOWN = 1
    # NX_KEYTYPE_MUTE = 7

    def __init__(self, callback):
        """
        callback: function(key_type) where key_type is 'up', 'down', or 'mute'
                 Should return True to pass through, False to suppress
        """
        self.callback = callback
        self.tap = None

    def start(self):
        """Start listening for volume keys"""
        # Create event tap for system-defined events
        self.tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap,
            Quartz.kCGHeadInsertEventTap,
            Quartz.kCGEventTapOptionDefault,
            Quartz.CGEventMaskBit(Quartz.kCGEventOtherMouseDown) |
            Quartz.CGEventMaskBit(Quartz.kCGEventOtherMouseUp),
            self._event_callback,
            None
        )

        if not self.tap:
            print("Failed to create event tap - check accessibility permissions")
            return False

        # Create run loop source and add to current run loop
        runLoopSource = Quartz.CFMachPortCreateRunLoopSource(None, self.tap, 0)
        Quartz.CFRunLoopAddSource(
            Quartz.CFRunLoopGetCurrent(),
            runLoopSource,
            Quartz.kCFRunLoopCommonModes
        )

        # Enable the tap
        Quartz.CGEventTapEnable(self.tap, True)

        print("Volume key listener started (Quartz event tap)")
        return True

    def _event_callback(self, proxy, event_type, event, refcon):
        """Handle events from the event tap"""
        try:
            # Only process system-defined events (includes media keys)
            if event_type != Quartz.kCGEventTapDisabledByTimeout and \
               event_type != Quartz.kCGEventTapDisabledByUserInput:

                ns_event = NSEvent.eventWithCGEvent_(event)
                if ns_event and ns_event.type() == NSSystemDefined and ns_event.subtype() == 8:
                    # Media key event
                    key_code = (ns_event.data1() & 0xFFFF0000) >> 16
                    key_flags = (ns_event.data1() & 0x0000FFFF)
                    key_state = (key_flags & 0xFF00) >> 8

                    # Only handle key down
                    if key_state == 0xA:
                        key_type = None
                        if key_code == 0:  # Volume Up
                            key_type = 'up'
                        elif key_code == 1:  # Volume Down
                            key_type = 'down'
                        elif key_code == 7:  # Mute
                            key_type = 'mute'

                        if key_type:
                            # Call callback - if it returns False, suppress the event
                            if not self.callback(key_type):
                                return None  # Suppress event

            return event  # Pass through

        except Exception as e:
            print(f"Error in event callback: {e}")
            return event