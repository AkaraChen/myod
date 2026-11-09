// Platform layer: windows, events, DPI, system theme. Currently built on SDL3.
package platform

import "base:runtime"
import "core:strings"

import sdl "../third_party/odin/sdl3"

// Redraw callback. While a window edge is being dragged, macOS takes over the event loop and the
// main loop is blocked, so redraws must be able to run directly inside SDL's event callback
// (see ARCHITECTURE.md, "Rendering backend").
Redraw_Proc :: #type proc(data: rawptr)

Window :: struct {
	handle:      ^sdl.Window,
	id:          Window_Id,
	redraw:      Redraw_Proc,
	redraw_data: rawptr,
	// Owned by the rendering backend (e.g. the Metal view on macOS), so it survives device loss.
	gpu_view:    rawptr,
}

Event_Kind :: enum {
	None,
	Other,
	Quit,
	Close_Requested, // the user asked to close a window (its close button)
	Theme_Changed,
	Key_Down,
	Key_Up,
	Text_Input, // committed text (typing, or the end of an input method composition)
	Text_Editing, // the input method's uncommitted composition (preedit)
	Wheel,
	Mouse_Move,
	Mouse_Down,
	Mouse_Up,
	Mouse_Leave,
	Focus_Gained,
	Focus_Lost,
	Wake, // from wake(), possibly sent by another thread
}

// Keys with a name. Printable keys arrive as `Key.Char` with the key's character in `char`
// (lowercase letters, digits, punctuation as on an unshifted US layout).
Key :: enum u8 {
	Unknown,
	Char,
	Enter,
	Escape,
	Backspace,
	Delete,
	Tab,
	Space,
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	Page_Up,
	Page_Down,
}

Modifier :: enum u8 {
	Shift,
	Ctrl,
	Alt, // Option on macOS
	Super, // Command on macOS
}
Modifiers :: bit_set[Modifier;u8]

Mouse_Button :: enum u8 {
	Left,
	Right,
	Middle,
	Other,
}

Event :: struct {
	kind:   Event_Kind,
	window: Window_Id, // the window the event is for; 0 if none
	// Key_Down / Key_Up
	key:    Key,
	char:   rune, // for Key.Char; also set for Space
	mods:   Modifiers, // keys and mouse buttons
	repeat: bool, // a key held down
	// Mouse_*: position in logical pixels from the window's top-left
	pos:    [2]f32,
	button: Mouse_Button,
	clicks: int, // 1, 2 (double click), 3 ...
	// Text_Input / Text_Editing: UTF-8, in context.temp_allocator
	text:   string,
	// Text_Editing: the selected part of the composition, in bytes; -1 if none
	cursor: [2]i32,
	// For Wheel: see Wheel_Info.
	wheel:  Wheel_Info,
}

Window_Id :: distinct u32

// A scroll, with the system's scroll direction setting (e.g. macOS natural scrolling) applied.
Wheel_Info :: struct {
	// Positive moves the content down and to the right, i.e. reveals what is above and to the left.
	// In logical pixels when `precise` (trackpads, Magic Mouse), otherwise in wheel notches.
	delta:   [2]f32,
	precise: bool,
	// The gesture this event belongs to, where the system reports it (macOS). Momentum events
	// continue a flick after the fingers lift; apps that do their own inertia can ignore them.
	phase:   Wheel_Phase,
}

Wheel_Phase :: enum u8 {
	None, // unknown (a mouse wheel, or a platform that does not say)
	Began,
	Changed,
	Ended,
	Cancelled,
	Momentum,
	Momentum_Ended,
}

// Wheel details read from the native event while SDL dispatches it, matched up by timestamp when
// the event is dequeued.
@(private)
g_wheels: [16]struct {
	timestamp: u64,
	info:      Wheel_Info,
}

@(private)
g_wheel_next: int

@(private)
g_context: runtime.Context

@(private)
g_wake_event: u32

init :: proc() -> bool {
	g_context = context
	if !sdl.Init({.VIDEO}) {
		return false
	}
	g_wake_event = sdl.RegisterEvents(1)
	return g_wake_event != 0
}

// Wakes a thread blocked in wait_event. Safe to call from any thread.
wake :: proc "contextless" (window: Window_Id = 0) {
	e: sdl.Event
	e.user = {type = sdl.EventType(g_wake_event), windowID = sdl.WindowID(window)}
	_ = sdl.PushEvent(&e)
}

shutdown :: proc() {
	sdl.Quit()
}

// The returned pointer stays valid until the window is closed; the event callback uses it to find the window.
open_window :: proc(title: string, width, height: i32) -> (^Window, bool) {
	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	handle := sdl.CreateWindow(ctitle, width, height, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if handle == nil {
		return nil, false
	}
	w := new(Window)
	w.handle = handle
	w.id = Window_Id(sdl.GetWindowID(handle))
	if !sdl.AddEventWatch(event_watch, w) {
		sdl.DestroyWindow(handle)
		free(w)
		return nil, false
	}
	return w, true
}

close_window :: proc(w: ^Window) {
	sdl.RemoveEventWatch(event_watch, w)
	sdl.DestroyWindow(w.handle)
	free(w)
}

// Sets the redraw callback. The platform layer calls it directly whenever the window needs a redraw
// (exposed, pixel size changed, display scale changed), including while a window edge is being dragged.
set_redraw :: proc(w: ^Window, redraw: Redraw_Proc, data: rawptr) {
	w.redraw = redraw
	w.redraw_data = data
}

// Blocks until the next event. Redraws do not go through here; the redraw callback handles them.
wait_event :: proc() -> Event {
	e: sdl.Event
	if !sdl.WaitEvent(&e) {
		return {kind = .Other}
	}
	return translate(e)
}

// Blocks until the next event or until `timeout_ms` passes (then returns an event of kind None).
wait_event_timeout :: proc(timeout_ms: i32) -> Event {
	e: sdl.Event
	if !sdl.WaitEventTimeout(&e, timeout_ms) {
		return {kind = .None}
	}
	return translate(e)
}

// Returns the next pending event without blocking, or an event of kind None.
poll_event :: proc() -> Event {
	e: sdl.Event
	if !sdl.PollEvent(&e) {
		return {kind = .None}
	}
	return translate(e)
}

@(private)
translate :: proc(e: sdl.Event) -> Event {
	if u32(e.type) == g_wake_event {
		return {kind = .Wake, window = Window_Id(e.user.windowID)}
	}
	#partial switch e.type {
	case .QUIT:
		return {kind = .Quit}
	case .SYSTEM_THEME_CHANGED:
		return {kind = .Theme_Changed}
	case .WINDOW_CLOSE_REQUESTED:
		return {kind = .Close_Requested, window = Window_Id(e.window.windowID)}
	case .WINDOW_FOCUS_GAINED:
		return {kind = .Focus_Gained, window = Window_Id(e.window.windowID)}
	case .WINDOW_FOCUS_LOST:
		return {kind = .Focus_Lost, window = Window_Id(e.window.windowID)}
	case .WINDOW_MOUSE_LEAVE:
		return {kind = .Mouse_Leave, window = Window_Id(e.window.windowID)}
	case .KEY_DOWN, .KEY_UP:
		key, char := key_of(e.key.key)
		return {
			kind = .Key_Down if e.key.down else .Key_Up,
			window = Window_Id(e.key.windowID),
			key = key,
			char = char,
			mods = mods_of(e.key.mod),
			repeat = e.key.repeat,
		}
	case .TEXT_INPUT:
		return {kind = .Text_Input, window = Window_Id(e.text.windowID), text = strings.clone_from_cstring(e.text.text, context.temp_allocator)}
	case .TEXT_EDITING:
		return {
			kind = .Text_Editing,
			window = Window_Id(e.edit.windowID),
			text = strings.clone_from_cstring(e.edit.text, context.temp_allocator),
			cursor = {e.edit.start, e.edit.length},
		}
	case .MOUSE_MOTION:
		return {kind = .Mouse_Move, window = Window_Id(e.motion.windowID), pos = {e.motion.x, e.motion.y}, mods = mods_of(sdl.GetModState())}
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		button: Mouse_Button
		switch e.button.button {
		case 1:
			button = .Left
		case 2:
			button = .Middle
		case 3:
			button = .Right
		case:
			button = .Other
		}
		return {
			kind = .Mouse_Down if e.button.down else .Mouse_Up,
			window = Window_Id(e.button.windowID),
			pos = {e.button.x, e.button.y},
			button = button,
			clicks = int(e.button.clicks),
			mods = mods_of(sdl.GetModState()),
		}
	case .MOUSE_WHEEL:
		ev := Event{kind = .Wheel, window = Window_Id(e.wheel.windowID), pos = {e.wheel.mouse_x, e.wheel.mouse_y}, mods = mods_of(sdl.GetModState())}
		for w in g_wheels {
			if w.timestamp == e.wheel.timestamp {
				ev.wheel = w.info
				return ev
			}
		}
		// No correction for `direction`: SDL's FLIPPED means the values already follow the user's
		// natural-scrolling setting, which is what content should follow. SDL's x is positive to
		// the right, the opposite of Wheel_Info.
		ev.wheel = {delta = {-e.wheel.x, e.wheel.y}}
		return ev
	}
	return {kind = .Other}
}

@(private)
mods_of :: proc(m: sdl.Keymod) -> Modifiers {
	r: Modifiers
	if m & {.LSHIFT, .RSHIFT} != {} {
		r += {.Shift}
	}
	if m & {.LCTRL, .RCTRL} != {} {
		r += {.Ctrl}
	}
	if m & {.LALT, .RALT} != {} {
		r += {.Alt}
	}
	if m & {.LGUI, .RGUI} != {} {
		r += {.Super}
	}
	return r
}

@(private)
key_of :: proc(k: sdl.Keycode) -> (Key, rune) {
	switch k {
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		return .Enter, 0
	case sdl.K_ESCAPE:
		return .Escape, 0
	case sdl.K_BACKSPACE:
		return .Backspace, 0
	case sdl.K_DELETE:
		return .Delete, 0
	case sdl.K_TAB:
		return .Tab, 0
	case sdl.K_SPACE:
		return .Space, ' '
	case sdl.K_LEFT:
		return .Left, 0
	case sdl.K_RIGHT:
		return .Right, 0
	case sdl.K_UP:
		return .Up, 0
	case sdl.K_DOWN:
		return .Down, 0
	case sdl.K_HOME:
		return .Home, 0
	case sdl.K_END:
		return .End, 0
	case sdl.K_PAGEUP:
		return .Page_Up, 0
	case sdl.K_PAGEDOWN:
		return .Page_Down, 0
	}
	if k > 0x20 && k < 0x7f {
		return .Char, rune(k)
	}
	return .Unknown, 0
}

// Window size in physical pixels.
pixel_size :: proc(w: ^Window) -> [2]u32 {
	pw, ph: i32
	sdl.GetWindowSizeInPixels(w.handle, &pw, &ph)
	return {u32(max(pw, 0)), u32(max(ph, 0))}
}

// Scale from logical to physical pixels, e.g. 2 on a Retina display.
display_scale :: proc(w: ^Window) -> f32 {
	s := sdl.GetWindowDisplayScale(w.handle)
	return s if s > 0 else 1
}

set_title :: proc(w: ^Window, title: string) {
	sdl.SetWindowTitle(w.handle, strings.clone_to_cstring(title, context.temp_allocator))
}

is_dark_theme :: proc() -> bool {
	return sdl.GetSystemTheme() == .DARK
}

@(private)
event_watch :: proc "c" (userdata: rawptr, event: ^sdl.Event) -> bool {
	context = g_context
	w := (^Window)(userdata)
	#partial switch event.type {
	case .MOUSE_WHEEL:
		if info, ok := native_wheel(); ok {
			g_wheels[g_wheel_next] = {event.wheel.timestamp, info}
			g_wheel_next = (g_wheel_next + 1) % len(g_wheels)
		}
	case .WINDOW_EXPOSED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_DISPLAY_SCALE_CHANGED:
		if Window_Id(event.window.windowID) == w.id && w.redraw != nil {
			w.redraw(w.redraw_data)
		}
	}
	return true
}

// Window size in logical pixels.
logical_size :: proc(w: ^Window) -> [2]f32 {
	lw, lh: i32
	sdl.GetWindowSize(w.handle, &lw, &lh)
	return {f32(lw), f32(lh)}
}

// Whether the window can show anything (not minimized or fully covered).
is_visible :: proc(w: ^Window) -> bool {
	flags := sdl.GetWindowFlags(w.handle)
	return flags & {.MINIMIZED, .OCCLUDED, .HIDDEN} == {}
}

// Text input (keyboard text and input methods) is only delivered between these calls.
start_text_input :: proc(w: ^Window) {
	_ = sdl.StartTextInput(w.handle)
}

stop_text_input :: proc(w: ^Window) {
	_ = sdl.StopTextInput(w.handle)
}

// Where the text being edited is, in logical pixels, so the input method's candidate window can
// follow it. `cursor` is the caret's x offset inside `rect`.
set_text_input_area :: proc(w: ^Window, rect: [4]f32, cursor: f32) {
	r := sdl.Rect{i32(rect[0]), i32(rect[1]), i32(rect[2]), i32(rect[3])}
	_ = sdl.SetTextInputArea(w.handle, &r, i32(cursor))
}

// The clipboard's text, in `allocator`; empty if it holds no text.
clipboard_text :: proc(allocator := context.temp_allocator) -> string {
	p := sdl.GetClipboardText()
	if p == nil {
		return ""
	}
	defer sdl.free(p)
	return strings.clone_from_cstring(cstring(p), allocator)
}

set_clipboard_text :: proc(s: string) {
	sdl.SetClipboardText(strings.clone_to_cstring(s, context.temp_allocator))
}

Cursor :: enum u8 {
	Default,
	Text,
	Pointer,
	Resize_Horizontal,
	Resize_Vertical,
	Not_Allowed,
}

@(private)
g_cursors: [Cursor]^sdl.Cursor

@(private)
g_cursor: Cursor

set_cursor :: proc(c: Cursor) {
	if c == g_cursor && g_cursors[c] != nil {
		return
	}
	if g_cursors[c] == nil {
		id: sdl.SystemCursor
		switch c {
		case .Default:
			id = .DEFAULT
		case .Text:
			id = .TEXT
		case .Pointer:
			id = .POINTER
		case .Resize_Horizontal:
			id = .EW_RESIZE
		case .Resize_Vertical:
			id = .NS_RESIZE
		case .Not_Allowed:
			id = .NOT_ALLOWED
		}
		g_cursors[c] = sdl.CreateSystemCursor(id)
	}
	_ = sdl.SetCursor(g_cursors[c])
	g_cursor = c
}

// Milliseconds since the platform layer started, for timers and double clicks.
ticks_ms :: proc() -> u64 {
	return sdl.GetTicks()
}
