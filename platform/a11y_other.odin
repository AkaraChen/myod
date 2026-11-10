#+build !darwin
package platform

// No system setting to follow yet: keep the conventional behaviour of showing a ring for keyboard
// focus. (The macOS layer reads the full keyboard access preference; see a11y_darwin.odin.)
keyboard_focus_rings :: proc() -> bool {
	return true
}
