// Windows and the event-driven frame loop (ARCHITECTURE.md, "API design → 1, 2, 8").
//
// `next_frame` is the whole frame machine: it waits for work (an input event, a message from a task,
// a timer, a requested redraw), runs the input phase and the message phase, and then asks the app to
// call `view` by returning true. Layout, the ghost-pass check and presenting happen at the start of
// the following call, because only then does the library know `view` has finished.
//
// The app's loop is therefore:
//
//	for ui.next_frame(&w) {
//	    view(store.state, ui.dispatcher(&store))
//	}
//
// Each `true` is exactly one `view`; a ghost pass or a message rerun simply returns true again.
package ui

import "base:builtin"
import "core:fmt"
import "core:os"
import "core:time"

import "../backend"
import "../core"
import "../devtools"
import "../platform"
import "../render"
import "../text"
import "../theme"

Window_Options :: struct {
	title: string,
	size:  [2]int,
}

// A window and everything that draws into it. Declare it in `main`; never copy it after
// `open_window` (widgets hold pointers into it).
Window :: struct {
	p:         ^platform.Window,
	gpu:       backend.Gpu,
	surface:   backend.Surface,
	renderer:  backend.Renderer,
	text:      text.Context,
	ctx:       core.Context,
	mode:      theme.Mode,
	mode_set:  bool, // the app chose the theme; system changes are ignored
	size:      [2]f32, // logical, as of the frame being declared
	scale:     f32,
	closed:    bool,
	// Event queue filled by the loop and drained by the input phase.
	events:    [dynamic]platform.Event,
	// Frame state.
	started:   bool, // frame_begin ran; frame_end has not
	declared:  bool, // `view` ran and its pass is not laid out yet
	pass:      int, // which view run of the current frame this is (1..MAX_PASSES)
	first:     bool, // nothing presented yet
	drawn:     bool, // a pass has been presented at least once
	presents:  int, // frames presented (tests assert that intermediate ones are not)
	outer:     ^core.Context, // current context before frame_begin, restored by frame_end
	last_hash: u64,
	last_size: [2]u32,
	// Scheduling.
	redraw_at: u64, // ms tick; 0 = no redraw requested
	redraw_pending: bool,
	store:     rawptr, // Store(S, M), through ops
	ops:       ^Store_Ops,
	focus_key: string, // from the focus effect, resolved after the next pass
	focus_buf: [256]u8,
	bound: bool, // the window holds its final address: self-pointers are set
	// Debug.
	debug_input: bool,
}

@(private, thread_local)
window_stack: [dynamic]^Window

@(private="file")
g_open_windows: int

open_window :: proc(o: Window_Options) -> Window {
	w: Window
	if g_open_windows == 0 {
		if !platform.init() {
			fmt.eprintln("myod: failed to initialize the platform layer")
			os.exit(1)
		}
	}
	ok: bool
	w.p, ok = platform.open_window(o.title, i32(o.size.x), i32(o.size.y))
	if !ok {
		fmt.eprintln("myod: failed to create a window")
		os.exit(1)
	}
	g_open_windows += 1
	w.gpu, w.surface, ok = backend.init(w.p)
	if !ok {
		os.exit(1)
	}
	w.renderer = backend.renderer_init(w.gpu, w.surface.config.format, w.surface.srgb)
	if !text.init(&w.text) {
		fmt.eprintln("myod: failed to load DWG from third_party/fonts (run from the repo root, or set MYOD_FONT_DIR)")
		os.exit(1)
	}
	if !core.init(&w.ctx, &w.text) {
		os.exit(1)
	}
	w.mode = .Dark if platform.is_dark_theme() else .Light
	w.scale = platform.display_scale(w.p)
	w.first = true
	w.debug_input = devtools.flags().input
	// The caller must keep this value at a stable address from here on (see the doc comment).
	return w
}

close_window :: proc(w: ^Window) {
	if w.closed {
		return
	}
	w.closed = true
	if w.ops != nil && w.ops.join != nil {
		w.ops.join(w.store)
	}
	delete(w.events)
	if w.p != nil {
		// Before the NSWindow goes away: the adapter unsubclasses its view.
		core.a11y_detach(&w.ctx)
	}
	core.destroy(&w.ctx)
	text.destroy(&w.text)
	if w.p != nil {
		backend.renderer_destroy(&w.renderer)
		backend.shutdown(&w.gpu, &w.surface)
		platform.close_window(w.p)
		g_open_windows -= 1
	}
	for i := len(window_stack) - 1; i >= 0; i -= 1 {
		if window_stack[i] == w {
			ordered_remove(&window_stack, i)
		}
	}
}

// Makes `w` current for the rest of the scope.
@(deferred_out = window_scope_end)
window_scope :: proc(w: ^Window) -> bool {
	assert(!w.closed, "myod: window_scope on a closed window")
	append(&window_stack, w)
	return true
}

@(private)
window_scope_end :: proc(ok: bool) {
	pop(&window_stack)
}

// The current window, for widgets. Asserted in debug builds.
current_window :: proc(loc := #caller_location) -> ^Window {
	assert(len(window_stack) > 0, "myod: a widget was used outside a frame", loc)
	return window_stack[len(window_stack) - 1]
}

// Asks for another frame `delay` after this one. Call it again every frame to keep redrawing
// (ARCHITECTURE.md, "API design → 2", continuous frames on demand).
request_redraw :: proc(delay: time.Duration = 0) {
	w := current_window()
	when ODIN_DEBUG {
		assert(w.declared, "myod: request_redraw outside view")
	}
	due := platform.ticks_ms() + u64(max(time.duration_milliseconds(delay), 0))
	if !w.redraw_pending || due < w.redraw_at {
		w.redraw_at = due
	}
	w.redraw_pending = true
}

// Wakes a window blocked in next_frame. Safe to call from any thread.
wake :: proc(w: ^Window) {
	platform.wake(w.p.id)
}

// The frame machine. Returns true when the app must call `view`; false when the window has closed.
next_frame :: proc(w: ^Window) -> bool {
	if w.closed {
		return false
	}
	if !w.bound {
		// `w` has its final address now (open_window returns by value): point the context at this
		// window's text, and let the live-resize callback keep the window pointer.
		w.ctx.text = &w.text
		if w.p != nil {
			platform.set_redraw(w.p, on_live_resize, w)
			// The accessibility adapter subclasses the window's view, so it must be created once the
			// view exists and while the window is at its final address.
			core.a11y_attach(&w.ctx, w.p)
		}
		w.bound = true
	}
	if w.declared {
		if finish_pass(w) {
			return true
		}
	}
	for {
		if w.closed {
			return false
		}
		wait_for_work(w)
		if w.closed {
			return false
		}
		collect_events(w)
		processed := process_messages(w)
		changed := handle_events(w)
		if w.closed {
			return false
		}
		if processed || changed || w.ctx.frame_requested || w.first || redraw_due(w) || messages_pending(w) {
			start_frame(w)
			return begin_pass(w)
		}
	}
}

// Lays out the pass the app declared and decides what happens next. Returns true when `view` must
// run again (a ghost pass or a message rerun).
@(private)
finish_pass :: proc(w: ^Window) -> bool {
	w.declared = false
	stable := core.pass_end(&w.ctx)
	if !stable && w.pass < core.MAX_PASSES {
		// Ghost pass: the messages this pass sent are dropped and `view` reruns with the new layout.
		if w.ops != nil {
			w.ops.discard(w.store)
		}
		collect_events(w)
		handle_events(w)
		return begin_pass(w)
	}
	if stable && w.ops != nil && w.ops.pending(w.store) {
		// The pass read the interaction results and sent messages: consume the results so the rerun
		// cannot send the same message again, then process them and rerun `view`.
		core.consume(&w.ctx)
		process_messages(w)
		return begin_pass(w)
	}
	if !stable {
		fmt.eprintln("myod: layout did not settle after", core.MAX_PASSES, "passes; presenting the last one")
	}
	if w.ops != nil {
		w.ops.commit(w.store)
	}
	core.consume(&w.ctx)
	present(w)
	return false
}

// Starts a pass. The frame itself (frame_begin) starts with the first pass after presenting.
@(private)
begin_pass :: proc(w: ^Window) -> bool {
	core.pass_begin(&w.ctx)
	w.declared = true
	w.pass += 1
	return true
}

@(private)
start_frame :: proc(w: ^Window) {
	if w.started {
		return
	}
	size := w.size
	scale := w.scale
	if w.p != nil {
		size = platform.logical_size(w.p)
		scale = platform.display_scale(w.p)
	}
	if size.x <= 0 || size.y <= 0 {
		size = {1, 1}
	}
	if scale <= 0 {
		scale = 1
	}
	w.size = size
	w.scale = scale
	w.pass = 0
	w.ctx.frame_requested = false
	text.begin_frame(&w.text)
	w.outer = core.frame_begin(&w.ctx, size, scale, theme.make_theme(w.mode), bounded = true)
	append(&window_stack, w)
	w.started = true
}

// ---- Waiting ----

@(private)
wait_for_work :: proc(w: ^Window) {
	if len(w.events) > 0 {
		return
	}
	_now := platform.ticks_ms()
	timeout: i64 = -1
	if w.redraw_pending {
		timeout = i64(w.redraw_at) - i64(_now)
	}
	if w.ops != nil {
		if deadline, ok := w.ops.timer_deadline(w.store); ok {
			ms := i64(deadline) - i64(_now)
			if timeout < 0 || ms < timeout {
				timeout = ms
			}
		}
	}
	if timeout < 0 && !w.first {
		// Nothing is due: block until an event or another thread's wake.
		e := platform.wait_event()
		if e.kind != .None {
			append(&w.events, e)
		}
		return
	}
	e := platform.wait_event_timeout(i32(clamp(timeout, 0, 1 << 30)))
	if e.kind != .None {
		append(&w.events, e)
	}
}

// Whether a requested redraw has come due.
@(private)
redraw_due :: proc(w: ^Window) -> bool {
	if !w.redraw_pending {
		return false
	}
	if platform.ticks_ms() >= w.redraw_at {
		w.redraw_pending = false
		return true
	}
	return false
}

@(private)
messages_pending :: proc(w: ^Window) -> bool {
	return w.ops != nil && (w.ops.pending(w.store) || w.ops.timer_due(w.store, platform.ticks_ms()))
}

// Drains every pending platform event into the queue.
@(private)
collect_events :: proc(w: ^Window) {
	for {
		e := platform.poll_event()
		if e.kind == .None {
			break
		}
		append(&w.events, e)
	}
}

// Runs the input phase over the queued events. Returns whether anything that is drawn may have
// changed.
@(private)
handle_events :: proc(w: ^Window) -> (changed: bool) {
	for e in w.events {
		if w.debug_input && e.kind != .Other && e.kind != .None {
			fmt.eprintln("input:", e)
		}
		#partial switch e.kind {
		case .Quit:
			w.closed = true
			return
		case .Close_Requested:
			if e.window == 0 || e.window == w.p.id {
				w.closed = true
				return
			}
		case .Theme_Changed:
			if !w.mode_set {
				w.mode = .Dark if platform.is_dark_theme() else .Light
				changed = true
			}
		case .Mouse_Move, .Mouse_Down, .Mouse_Up, .Mouse_Leave, .Wheel, .Key_Down, .Key_Up, .Text_Input, .Text_Editing, .Focus_Gained, .Focus_Lost:
			if e.kind == .Focus_Gained || e.kind == .Focus_Lost {
				core.a11y_window_focus(&w.ctx, e.kind == .Focus_Gained)
			}
			if core.handle_event(&w.ctx, e) {
				changed = true
			}
		case .Wake, .Other, .None:
		}
	}
	clear(&w.events)
	return
}

// ---- Messages ----

// Runs the message phase over what `view` sent and what the tasks and timers produced. Returns
// whether any message reached `update` (state changed, so a frame is due).
@(private)
process_messages :: proc(w: ^Window) -> (processed: bool) {
	if w.ops == nil {
		return
	}
	processed = w.ops.run_timers(w.store, platform.ticks_ms())
	processed = w.ops.process(w.store) || processed
	if w.focus_key != "" {
		apply_focus(w)
	}
	return
}

@(private)
apply_focus :: proc(w: ^Window) {
	id, ok := core.name_id(&w.ctx, w.focus_key)
	if ok {
		core.set_focus(&w.ctx, id, true)
	}
	w.focus_key = ""
}

@(private)
request_focus :: proc(w: ^Window, key: string) {
	n := min(copy(w.focus_buf[:], key), len(w.focus_buf))
	w.focus_key = string(w.focus_buf[:n])
}

// ---- Presenting ----

@(private)
present :: proc(w: ^Window) {
	defer {
		if w.started {
			// frame_end has restored the context; the window stops being current.
			w.started = false
			if len(window_stack) > 0 && window_stack[len(window_stack) - 1] == w {
				pop(&window_stack)
			}
		}
	}
	size: [2]u32
	scale := w.scale
	if w.p != nil {
		size = platform.pixel_size(w.p)
		if size.x == 0 || size.y == 0 {
			return
		}
		if scale <= 0 {
			scale = platform.display_scale(w.p)
		}
	}
	t := theme.make_theme(w.mode)
	list := render.make_command_list()
	core.frame_end(&w.ctx, &list, w.outer)
	w.started = false
	if w.p != nil {
		// After frame_end, which built the pass's semantic tree. AccessKit wants physical pixels.
		core.a11y_publish(&w.ctx, scale, size)
		add_overlays(w, &list)
		submit(w, &list, size, scale, t)
	}
	w.presents += 1
	w.drawn = true
	w.first = false
}

@(private)
add_overlays :: proc(w: ^Window, list: ^render.Command_List) {
	flags := devtools.flags()
	if !flags.atlas && !flags.render {
		return
	}
	t := theme.make_theme(w.mode)
	if flags.atlas {
		devtools.atlas_overlay(list, &w.text, w.size, w.scale, t)
	}
	if flags.render {
		devtools.render_overlay(list, &w.text, w.renderer.stats, w.size, w.scale, t, &w.ctx.stats)
	}
}

// Presents a command list, skipping the GPU work when nothing changed.
@(private)
submit :: proc(w: ^Window, list: ^render.Command_List, size: [2]u32, scale: f32, t: theme.Theme) {
	if backend.device_lost(w.gpu) {
		backend.renderer_destroy(&w.renderer)
		if !backend.recover(&w.gpu, &w.surface, w.p) {
			os.exit(1)
		}
		w.renderer = backend.renderer_init(w.gpu, w.surface.config.format, w.surface.srgb)
		w.last_hash = 0
	}
	h := hash_commands(list)
	unchanged := h == w.last_hash && size == w.last_size && w.drawn
	if !unchanged {
		frame, ok := backend.begin_frame(w.gpu, &w.surface, size)
		if !ok {
			return
		}
		backend.renderer_draw(w.gpu, &w.renderer, frame.encoder, frame.view, size, scale, list^, t.on_bg.bg, &w.text.atlases)
		backend.end_frame(w.gpu, &w.surface, frame)
		w.last_hash = h
		w.last_size = size
	}
}

// A content hash of the command list: equal lists present identically, so the GPU can be skipped.
@(private)
hash_commands :: proc(list: ^render.Command_List) -> u64 {
	h: u64 = 0x9e3779b97f4a7c15
	for c in list.commands {
		switch v in c {
		case render.Cmd_Rect:
			x := v
			h = core.hash_words(h, &x, builtin.size_of(x))
		case render.Cmd_Clip_Push:
			x := v
			h = core.hash_words(h, &x, builtin.size_of(x))
		case render.Cmd_Clip_Pop:
			h = core.mix(h, 0x636c69705f706f70)
		case render.Cmd_Glyph_Run:
			origin := v.origin
			color := v.color
			h = core.hash_words(h, &origin, builtin.size_of(origin))
			h = core.hash_words(h, &color, builtin.size_of(color))
			h = core.hash_words(h, raw_data(v.quads), len(v.quads) * builtin.size_of(render.Glyph_Quad))
			h = core.mix(h, u64(len(v.quads)))
		case render.Cmd_Atlas_View:
			x := v
			h = core.hash_words(h, &x, builtin.size_of(x))
		case render.Cmd_Image:
			h = core.mix(h, v.key)
			h = core.mix(h, v.version)
			r := [4]f32{v.rect.x, v.rect.y, v.rect.w, v.rect.h}
			uv := [4]f32{v.uv.x, v.uv.y, v.uv.w, v.uv.h}
			h = core.hash_words(h, &r, builtin.size_of(r))
			h = core.hash_words(h, &uv, builtin.size_of(uv))
			c := v.color
			h = core.hash_words(h, &c, builtin.size_of(c))
		}
	}
	return core.mix(h, u64(len(list.commands)))
}

// ---- Live resize ----

// Called by the platform from inside SDL's event callback while a window edge is dragged: the event
// loop is blocked then, so the last pass is laid out again at the new size and presented directly.
@(private)
on_live_resize :: proc(data: rawptr) {
	w := (^Window)(data)
	if w.closed || !w.drawn || w.declared || len(w.ctx.trees[w.ctx.cur].nodes) == 0 {
		return
	}
	size := platform.pixel_size(w.p)
	if size.x == 0 || size.y == 0 {
		return
	}
	scale := w.scale if w.scale > 0 else platform.display_scale(w.p)
	t := theme.make_theme(w.mode)
	logical := [2]f32{f32(size.x) / scale, f32(size.y) / scale}
	text.begin_frame(&w.text)
	list := render.make_command_list()
	core.relayout(&w.ctx, logical, scale, t, &list)
	submit(w, &list, size, scale, t)
	free_all(context.temp_allocator)
}

// ---- Theme ----

// Switches the window's theme; system theme changes are then ignored.
set_theme :: proc(mode: theme.Mode) {
	w := current_window()
	if w.mode == mode && w.mode_set {
		return
	}
	w.mode = mode
	w.mode_set = true
	// Applied to the frame being declared too, so switching in `view` changes this frame, not the next.
	w.ctx.theme = theme.make_theme(mode)
}

// The window's current theme.
theme_mode :: proc() -> theme.Mode {
	return current_window().mode
}
