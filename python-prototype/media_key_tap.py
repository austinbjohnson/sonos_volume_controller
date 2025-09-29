#!/usr/bin/env python3
"""
Media key interceptor using NSEvent monitoring
"""

from AppKit import NSEvent, NSSystemDefined
from Foundation import NSObject, NSRunLoop, NSDefaultRunLoopMode
from Cocoa import NSKeyUp


class MediaKeyTap(NSObject):
    """Monitor system events for media keys"""

    def initWithCallback_(self, callback):
        self = super(MediaKeyTap, self).init()
        if self is None:
            return None
        self.callback = callback
        self.monitor = None
        return self

    def start(self):
        """Start monitoring for media keys"""
        # Monitor system-defined events (media keys)
        self.monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            NSSystemDefined,
            self.handle_event
        )

        # Also add local monitor to catch events when app is active
        self.local_monitor = NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
            NSSystemDefined,
            self.handle_event_local
        )

        if self.monitor or self.local_monitor:
            print("Media key monitor started")
            return True
        else:
            print("Failed to create media key monitor")
            return False

    def handle_event(self, event):
        """Handle global events"""
        if event.type() == NSSystemDefined and event.subtype() == 8:
            self.process_media_key(event)

    def handle_event_local(self, event):
        """Handle local events and optionally suppress"""
        if event.type() == NSSystemDefined and event.subtype() == 8:
            should_pass = self.process_media_key(event)
            if not should_pass:
                return None  # Suppress event
        return event

    def process_media_key(self, event):
        """Process media key event"""
        try:
            data1 = event.data1()
            key_code = (data1 & 0xFFFF0000) >> 16
            key_flags = (data1 & 0x0000FFFF)
            key_state = (key_flags & 0xFF00) >> 8
            key_repeat = (key_flags & 0x1)

            # Only handle key down (not repeat)
            if key_state == 0xA and key_repeat == 0:
                key_type = None
                if key_code == 16:  # Volume Up
                    key_type = 'up'
                elif key_code == 17:  # Volume Down
                    key_type = 'down'
                elif key_code == 18:  # Mute
                    key_type = 'mute'

                if key_type and self.callback:
                    # Call callback - if it returns False, suppress the event
                    return self.callback(key_type)

            return True  # Pass through by default

        except Exception as e:
            print(f"Error processing media key: {e}")
            return True

    def stop(self):
        """Stop monitoring"""
        if self.monitor:
            NSEvent.removeMonitor_(self.monitor)
        if hasattr(self, 'local_monitor') and self.local_monitor:
            NSEvent.removeMonitor_(self.local_monitor)