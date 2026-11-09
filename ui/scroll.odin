// Scroll helpers: the `on_end` message of a scroll container (ARCHITECTURE.md, "API design → 15").
package ui

import "../core"

// A scrolling column that also reports when it reaches the end: `on_end` is sent to `update` once
// each time the content's bottom comes into view (paging, infinite lists).
@(deferred_out = _close)
scroll_events :: proc(d: Dispatch($M), on_end: M, o: Container_Options = {}) -> bool {
	ctx := core.current()
	opts := o
	opts.clip = true
	id := key_id(ctx, opts.id)
	opened := open_box(opts, .Column, {.Scroll})
	if opened {
		st, _ := core.state(ctx, id, Scroll_State)
		_, max, ok := core.scroll_limits(ctx, id)
		off := core.scroll_offset(ctx, id)
		at_end := ok && max.y > 0 && off.y >= max.y - 1
		if at_end && !st.at_end {
			dispatch(d, on_end)
		}
		st.at_end = at_end
	}
	return opened
}

@(private)
Scroll_State :: struct {
	at_end: bool,
}

// Whether the scroll container with this key is at its bottom. Call it in `view` (it reads the
// position from the last layout).
scroll_at_end :: proc(key: Key) -> bool {
	ctx := core.current()
	id := key_id(ctx, key)
	_, max, ok := core.scroll_limits(ctx, id)
	if !ok || max.y <= 0 {
		return false
	}
	return core.scroll_offset(ctx, id).y >= max.y - 1
}

// The scroll offset of a container, for apps that mirror it.
scroll_position :: proc(key: Key) -> [2]f32 {
	return core.scroll_offset(core.current(), key_id(core.current(), key))
}
