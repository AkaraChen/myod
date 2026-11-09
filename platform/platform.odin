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
	id:          sdl.WindowID,
	redraw:      Redraw_Proc,
	redraw_data: rawptr,
	// Owned by the rendering backend (e.g. the Metal view on macOS), so it survives device loss.
	gpu_view:    rawptr,
}

Event_Kind :: enum {
	None,
	Other,
	Quit,
	Theme_Changed,
	Key_Down,
}

Event :: struct {
	kind: Event_Kind,
	// For Key_Down: the key code. Letters are lowercase ASCII, digits are ASCII digits.
	key:  rune,
}

@(private)
g_context: runtime.Context

init :: proc() -> bool {
	g_context = context
	return sdl.Init({.VIDEO})
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
	w.id = sdl.GetWindowID(handle)
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
	#partial switch e.type {
	case .QUIT:
		return {kind = .Quit}
	case .SYSTEM_THEME_CHANGED:
		return {kind = .Theme_Changed}
	case .KEY_DOWN:
		if !e.key.repeat {
			return {kind = .Key_Down, key = rune(e.key.key)}
		}
	}
	return {kind = .Other}
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
	case .WINDOW_EXPOSED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_DISPLAY_SCALE_CHANGED:
		if event.window.windowID == w.id && w.redraw != nil {
			w.redraw(w.redraw_data)
		}
	}
	return true
}
