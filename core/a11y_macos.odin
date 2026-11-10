#+build darwin
// The macOS AccessKit bridge (ARCHITECTURE.md, "API design → 17"): the semantic tree goes to
// ffi/src/a11y.rs as a flat array of C structs, which exposes it through the window's NSView.
// Screen-reader actions come back through `ax_action` and enter the input phase as synthetic
// activations, the same results a click produces, so `view` cannot tell them apart.
package core

import "base:runtime"
import "core:fmt"

import "../platform"

// Mirrors `MyodAxNode` in ffi/src/a11y.rs, field for field.
Ax_Node :: struct {
	id:         u64,
	parent:     i64,
	role:       u32,
	flags:      u32,
	actions:    u32,
	row_count:    i32,
	row_index:    i32,
	column_count: i32,
	column_index: i32,
	x, y, w, h: f64,
	name:       [^]u8,
	name_len:   uintptr,
	value:      [^]u8,
	value_len:  uintptr,
	text:       [^]u8,
	text_len:   uintptr,
	char_lengths:     [^]u8,
	char_lengths_len: uintptr,
	word_starts:      [^]u8,
	word_starts_len:  uintptr,
	char_positions:     [^]f32,
	char_positions_len: uintptr,
	char_widths:        [^]f32,
	char_widths_len:    uintptr,
	sel_a:      i32,
	sel_b:      i32,
}

foreign {
	myod_a11y_init :: proc "c" (ns_window: rawptr, cb: proc "c" (id: u64, action: u32)) -> rawptr ---
	myod_a11y_update :: proc "c" (a: rawptr, nodes: [^]Ax_Node, count: uintptr, focus: u64, width, height: f64) ---
	myod_a11y_set_focus :: proc "c" (a: rawptr, focused: bool) ---
	myod_a11y_destroy :: proc "c" (a: rawptr) ---
}

@(private)
ax_ctx: ^Context

@(private)
ax_window: platform.Window_Id

// The Odin context of the thread that created the adapter: AccessKit calls back on the same thread,
// but from Objective-C, where Odin's implicit context is not set.
@(private)
ax_runtime: runtime.Context

// Called by AccessKit on the main thread when a screen reader presses or focuses a widget.
@(private)
ax_action :: proc "c" (id: u64, action: u32) {
	context = ax_runtime
	ctx := ax_ctx
	if ctx == nil {
		return
	}
	switch action {
	case 1:
		if ctx.a11y_log {
			fmt.eprintln("a11y action: click", id)
		}
		activate(ctx, Id(id))
	case 2:
		if ctx.a11y_log {
			fmt.eprintln("a11y action: focus", id)
		}
		set_focus(ctx, Id(id), true)
		// A screen reader moving to a row scrolls it into view, like the keyboard does.
		ensure_visible(ctx, Id(id))
	}
	// The action changed an interaction result: the app must run a pass to see it.
	ctx.frame_requested = true
	if ax_window != 0 {
		// The app is probably blocked in the event wait: wake it to run the input phase.
		platform.wake(ax_window)
	}
}

// Hooks the window's view up to the accessibility system. Must run on the main thread, before
// anything observes the view.
a11y_attach :: proc(ctx: ^Context, p: ^platform.Window) {
	view := platform.native_window(p)
	if view == nil {
		return
	}
	ax_ctx = ctx
	ax_window = p.id
	ax_runtime = context
	ctx.ax = myod_a11y_init(view, ax_action)
}

// Tells the adapter whether the window has keyboard focus, so it can follow the host's focus state.
a11y_window_focus :: proc(ctx: ^Context, focused: bool) {
	if ctx.ax != nil {
		myod_a11y_set_focus(ctx.ax, focused)
	}
}

a11y_detach :: proc(ctx: ^Context) {
	if ctx.ax != nil {
		myod_a11y_destroy(ctx.ax)
		ctx.ax = nil
	}
	if ax_ctx == ctx {
		ax_ctx = nil
		ax_window = 0
	}
}

// Publishes the pass's semantic tree. `scale` converts logical rects to the physical pixels AccessKit
// expects; `physical` is the window's pixel size.
a11y_publish :: proc(ctx: ^Context, scale: f32, physical: [2]u32) {
	if ctx.ax == nil {
		return
	}
	nodes := make([]Ax_Node, len(ctx.a11y), context.temp_allocator)
	for n, i in ctx.a11y {
		// Text run positions are in the same space as the node's bounds: physical pixels.
		positions: []f32
		widths: []f32
		if len(n.char_positions) > 0 {
			positions = make([]f32, len(n.char_positions), context.temp_allocator)
			for x, k in n.char_positions {
				positions[k] = x * scale
			}
		}
		if len(n.char_widths) > 0 {
			widths = make([]f32, len(n.char_widths), context.temp_allocator)
			for w, k in n.char_widths {
				widths[k] = w * scale
			}
		}
		nodes[i] = {
			id      = u64(n.id),
			parent  = i64(n.parent),
			role    = u32(n.role),
			flags   = u32(transmute(u8)n.flags),
			actions = u32(transmute(u8)n.actions),
			row_count    = n.row_count,
			row_index    = n.row_index,
			column_count = n.column_count,
			column_index = n.column_index,
			x       = f64(n.rect.x) * f64(scale),
			y       = f64(n.rect.y) * f64(scale),
			w       = f64(n.rect.w) * f64(scale),
			h       = f64(n.rect.h) * f64(scale),
			name    = raw_data(n.name),
			name_len = uintptr(len(n.name)),
			value   = raw_data(n.value),
			value_len = uintptr(len(n.value)),
			text      = raw_data(n.text),
			text_len  = uintptr(len(n.text)),
			char_lengths     = raw_data(n.char_lengths),
			char_lengths_len = uintptr(len(n.char_lengths)),
			word_starts      = raw_data(n.word_starts),
			word_starts_len  = uintptr(len(n.word_starts)),
			char_positions     = raw_data(positions),
			char_positions_len = uintptr(len(positions)),
			char_widths        = raw_data(widths),
			char_widths_len    = uintptr(len(widths)),
			sel_a     = n.sel_a,
			sel_b     = n.sel_b,
		}
	}
	focus := u64(ctx.input.focus)
	myod_a11y_update(ctx.ax, raw_data(nodes), uintptr(len(nodes)), focus, f64(physical.x), f64(physical.y))
}
