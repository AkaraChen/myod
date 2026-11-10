// Text selection (ARCHITECTURE.md, "API design → 16"): one selection per window over the body text,
// drag-selected in document order — the order `view` declares nodes in. Text inside an interactive
// widget (a button, a menu item, text declared `interactive`) is not selectable: pressing there
// operates the widget. A selection does not span layers: only base content is selectable.
//
// The selection is presentation state: it lives here, not in the app. What the app reads is the
// clipboard (Command / Control + C).
package core

import "core:strings"

import "../platform"
import "../text"

// A place in a text node: a widget ID and a byte offset into its string.
Text_Pos :: struct {
	id:     Id,
	offset: int,
}

Text_Selection :: struct {
	active:   bool,
	anchor:   Text_Pos, // where the drag began; it does not move
	cursor:   Text_Pos, // the changing end; equal to the anchor when nothing is selected
	dragging: bool,
}

// Whether there is a selection to copy or draw.
has_selection :: proc(ctx: ^Context) -> bool {
	return ctx.sel.active && (ctx.sel.anchor.id != ctx.sel.cursor.id || ctx.sel.anchor.offset != ctx.sel.cursor.offset)
}

// Starts a drag selection at `pos`.
@(private)
selection_begin :: proc(ctx: ^Context, pos: Text_Pos) {
	ctx.sel = Text_Selection{active = true, anchor = pos, cursor = pos, dragging = true}
}

@(private)
selection_clear :: proc(ctx: ^Context) {
	if ctx.sel.active {
		ctx.sel = {}
	}
}

// Extends a drag to the pointer. Called from the input phase; a pointer outside any text leaves the
// selection where it was.
@(private)
selection_drag :: proc(ctx: ^Context) {
	if !ctx.sel.dragging {
		return
	}
	if pos, ok := text_hit(ctx, pointer(ctx)); ok {
		ctx.sel.cursor = pos
	}
}

// A double click on release selects the word under the pointer, a triple click its paragraph (the
// text between explicit line breaks).
@(private)
selection_click :: proc(ctx: ^Context, clicks: int) {
	if !ctx.sel.active || clicks < 2 {
		return
	}
	s, ok := selection_text(ctx, ctx.sel.cursor.id)
	if !ok || len(s) == 0 {
		return
	}
	at := clamp(ctx.sel.cursor.offset, 0, len(s))
	a, b: int
	if clicks == 2 {
		a, b = text.word_at(s, at)
	} else {
		a, b = at, at
		for a > 0 && s[a - 1] != '\n' {
			a -= 1
		}
		for b < len(s) && s[b] != '\n' {
			b += 1
		}
	}
	ctx.sel.anchor = {ctx.sel.cursor.id, a}
	ctx.sel.cursor = {ctx.sel.cursor.id, b}
}

// ---- Looking up nodes ----

@(private)
selection_text :: proc(ctx: ^Context, id: Id) -> (string, bool) {
	i, ok := selection_index(ctx, id)
	if !ok {
		return "", false
	}
	t := &ctx.trees[ctx.cur]
	if pt, is_text := t.nodes[i].paint.(Paint_Text); is_text {
		return pt.s, true
	}
	return "", false
}

@(private)
selection_index :: proc(ctx: ^Context, id: Id) -> (int, bool) {
	slot, ok := ctx.slot_of[id]
	if !ok {
		return 0, false
	}
	s := &ctx.slots[slot]
	t := &ctx.trees[ctx.cur]
	if s.seen != ctx.stamp || s.index < 0 || int(s.index) >= len(t.nodes) || t.nodes[s.index].id != id {
		return 0, false
	}
	return int(s.index), true
}

// A text node that can be selected: it draws text, takes no input itself, and is not inside a
// widget that does (or inside a layer).
@(private)
selection_selectable :: proc(ctx: ^Context, index: int) -> bool {
	t := &ctx.trees[ctx.cur]
	n := &t.nodes[index]
	if _, is_text := n.paint.(Paint_Text); !is_text {
		return false
	}
	if .Hit in n.flags || .Disabled in n.flags || .Culled in n.flags || .Layer in n.flags {
		return false
	}
	for a := n.parent; a >= 0; a = t.nodes[a].parent {
		an := &t.nodes[a]
		if .Hit in an.flags || .Disabled in an.flags || .Text_Edit in an.flags || .Layer in an.flags || .Culled in an.flags {
			return false
		}
	}
	return true
}

// ---- Hit testing ----

// The text position nearest `p` (root coordinates), or false when no selectable text is under it.
@(private)
text_hit :: proc(ctx: ^Context, p: [2]f32) -> (pos: Text_Pos, ok: bool) {
	t := &ctx.trees[ctx.cur]
	for i := len(t.nodes) - 1; i >= 0; i -= 1 {
		n := &t.nodes[i]
		if n.rect.w <= 0 || n.rect.h <= 0 || !contains(n.rect, p) || !selection_selectable(ctx, i) {
			continue
		}
		inside := true
		for a := n.parent; a >= 0; a = t.nodes[a].parent {
			anc := &t.nodes[a]
			if .Culled in anc.flags || (.Clip in anc.flags && !contains(anc.rect, p)) {
				inside = false
				break
			}
		}
		if !inside {
			continue
		}
		if pt, is_text := n.paint.(Paint_Text); is_text {
			return {n.id, text_offset_at(ctx, n, pt, p)}, true
		}
	}
	return {}, false
}

// The byte offset of the character nearest `p` in one text node.
@(private)
text_offset_at :: proc(ctx: ^Context, n: ^Node, pt: Paint_Text, p: [2]f32) -> int {
	s := pt.s
	if len(s) == 0 {
		return 0
	}
	scale := ctx.scale
	style := pt.style
	x_at := text.caret_positions(ctx.text, s, style, scale)
	line: text.Line
	if pt.wrap {
		lines := text.wrap(ctx.text, s, style, n.rect.w + 0.5 / scale, scale)
		if len(lines) == 0 {
			return 0
		}
		li := clamp(int((p.y - n.rect.y) / style.line_height), 0, len(lines) - 1)
		line = lines[li]
	} else {
		line = text.Line{start = 0, end = len(s), x0 = 0}
	}
	x := p.x - n.rect.x
	x0 := line.x0 / scale
	best, best_d := line.start, abs(x_at[line.start] - x0 - x)
	for i in line.start + 1 ..= line.end {
		// `caret_positions` back-fills the bytes inside a character with the next boundary's x, so a
		// scan that accepted them would return an offset inside a multi-byte character.
		if i < len(s) && s[i] & 0xC0 == 0x80 {
			continue
		}
		d := abs(x_at[i] - x0 - x)
		if d < best_d {
			best, best_d = i, d
		}
	}
	return best
}

// ---- Ordering, drawing and copying ----

// The selection's endpoints in document order: (first index, first offset, last index, last offset).
@(private)
selection_order :: proc(ctx: ^Context) -> (ai, bi, ao, bo: int, ok: bool) {
	i_a, ok_a := selection_index(ctx, ctx.sel.anchor.id)
	i_b, ok_b := selection_index(ctx, ctx.sel.cursor.id)
	if !ok_a || !ok_b {
		return 0, 0, 0, 0, false
	}
	ai, bi = i_a, i_b
	ao, bo = ctx.sel.anchor.offset, ctx.sel.cursor.offset
	if ai > bi || (ai == bi && ao > bo) {
		ai, bi = bi, ai
		ao, bo = bo, ao
	}
	return ai, bi, ao, bo, true
}

// The part of the text node at `index` that the selection covers, for drawing ([a, b) bytes).
@(private)
selection_text_range :: proc(ctx: ^Context, index: int, s: string) -> (a, b: int, ok: bool) {
	if !ctx.sel.active || len(s) == 0 || !selection_selectable(ctx, index) {
		return 0, 0, false
	}
	ai, bi, ao, bo, ordered := selection_order(ctx)
	if !ordered || index < ai || index > bi {
		return 0, 0, false
	}
	switch {
	case ai == bi:
		a, b = clamp(ao, 0, len(s)), clamp(bo, 0, len(s))
	case index == ai:
		a, b = clamp(ao, 0, len(s)), len(s)
	case index == bi:
		a, b = 0, clamp(bo, 0, len(s))
	case:
		a, b = 0, len(s)
	}
	return a, b, b > a
}

// The selected text as plain text, one line per text node. Returns whether there is anything to
// copy.
selection_string :: proc(ctx: ^Context, allocator := context.temp_allocator) -> (string, bool) {
	if !has_selection(ctx) {
		return "", false
	}
	ai, bi, ao, bo, ok := selection_order(ctx)
	if !ok {
		return "", false
	}
	b := strings.builder_make(allocator)
	copied := false
	for i := ai; i <= bi; i += 1 {
		s, is_text := selection_text(ctx, ctx.trees[ctx.cur].nodes[i].id)
		if !is_text {
			continue
		}
		a, z := 0, len(s)
		if i == ai {
			a = clamp(ao, 0, len(s))
		}
		if i == bi {
			z = clamp(bo, 0, len(s))
		}
		if a >= z {
			continue
		}
		if copied && strings.builder_len(b) > 0 && strings.to_string(b)[strings.builder_len(b) - 1] != '\n' {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, s[a:z])
		copied = true
	}
	if !copied {
		return "", false
	}
	return strings.to_string(b), true
}

// Copies the selection to the clipboard.
@(private)
selection_copy :: proc(ctx: ^Context) -> bool {
	s, ok := selection_string(ctx, context.temp_allocator)
	if !ok {
		return false
	}
	platform.set_clipboard_text(s)
	return true
}
