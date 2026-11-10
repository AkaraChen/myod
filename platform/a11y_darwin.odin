#+build darwin
package platform

import NSApp "vendor:darwin/AppKit"

// Whether the user has turned on full keyboard access (System Settings → Accessibility → Keyboard).
// It is the system's way of saying the keyboard is one of the primary ways they move around the
// interface, so focus rings are drawn when focus comes from it. With it off (the default) the
// pointer is the primary input, and a ring around every clicked control is just noise.
keyboard_focus_rings :: proc() -> bool {
	return bool(NSApp.Application_isFullKeyboardAccessEnabled(NSApp.Application_sharedApplication()))
}
