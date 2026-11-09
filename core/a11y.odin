// The semantic tree (ARCHITECTURE.md, "API design → 17"): built after every pass from the node array,
// one entry per widget that means something to a user, with its role, name, value, state and the
// actions it takes. Node IDs are widget IDs, so the tree is stable across frames and differential
// updates (AccessKit) and lookups by role and name (test harness) are cheap.
//
// Widgets do not declare semantics separately: a text node is static text named by its string, a
// node with `Hit` and `Focusable` is a button named by the label it was declared with.
package core

import "core:fmt"
import "core:os"
import "core:strings"

Role :: enum u8 {
	None,
	Group,
	Button,
	Static_Text,
	Image,
	Textbox,
	Checkbox,
	Radio,
	Slider,
	Progress,
	Tab,
	Tab_Panel,
	List,
	List_Item,
	Menu,
	Menu_Item,
	Dialog,
}

A11y_Flag :: enum u8 {
	Disabled,
	Focused,
	Focus_Visible,
	Selected,
	Checked,
	Expanded,
	Pressed,
	Read_Only,
}
A11y_Flags :: bit_set[A11y_Flag;u8]

A11y_Action :: enum u8 {
	Click, // press it
	Focus,
	Set_Value,
}
A11y_Actions :: bit_set[A11y_Action;u8]

// One widget in the semantic tree. `parent` indexes the tree (-1 for a root).
A11y_Node :: struct {
	id:          Id,
	parent:      int,
	role:        Role,
	name:        string,
	description: string,
	value:       string,
	rect:        Rect,
	flags:       A11y_Flags,
	actions:     A11y_Actions,
}

// The semantic tree of the last pass.
a11y :: proc(ctx: ^Context) -> []A11y_Node {
	return ctx.a11y[:]
}

// The entry for a widget ID, if it is in the tree.
a11y_find :: proc(ctx: ^Context, id: Id) -> (^A11y_Node, bool) {
	for &n in ctx.a11y {
		if n.id == id {
			return &n, true
		}
	}
	return nil, false
}

// Derives a node's semantics from what it draws and how it takes input. Called when the node is
// declared, after its flags are known.
@(private)
a11y_declare :: proc(n: ^Node, label: string) {
	n.role = .None
	n.name = label
	switch p in n.paint {
	case Paint_Text:
		n.role = .Static_Text
		if n.name == "" {
			n.name = p.s
		}
	case Paint_Icon:
		n.role = .Image
	case Paint_Box, Paint_Line:
		if label != "" {
			n.role = .Group
		}
	}
	if .Hit in n.flags && .Focusable in n.flags {
		n.role = .Button
		if n.name == "" {
			n.name = label
		}
	}
}

// ---- Building ----

// Fills `ctx.a11y` from the laid-out node array. Excluded nodes (plain containers, unnamed images,
// culled placeholders) are skipped and their children attach to the nearest included ancestor.
@(private)
a11y_build :: proc(ctx: ^Context) {
	t := &ctx.trees[ctx.cur]
	clear(&ctx.a11y)
	incl := make([]i32, len(t.nodes), context.temp_allocator)
	for i := 0; i < len(t.nodes); i += 1 {
		n := &t.nodes[i]
		incl[i] = -1
		if n.role == .None || .Culled in n.flags {
			continue
		}
		parent: int = -1
		if n.parent >= 0 {
			pi := incl[n.parent]
			if pi >= 0 {
				parent = int(pi)
			}
		}
		flags := A11y_Flags{}
		disabled := is_disabled(t, i32(i))
		if disabled {
			flags += {.Disabled}
		}
		if n.id == ctx.input.focus {
			flags += {.Focused}
			if ctx.input.focus_visible {
				flags += {.Focus_Visible}
			}
		}
		actions := A11y_Actions{}
		if !disabled {
			if .Hit in n.flags {
				actions += {.Click}
			}
			if .Focusable in n.flags {
				actions += {.Focus}
			}
		}
		a := A11y_Node {
			id      = n.id,
			parent  = parent,
			role    = n.role,
			name    = n.name,
			value   = n.a11y_value,
			rect    = n.rect,
			flags   = flags,
			actions = actions,
		}
		if a.name == "" && a.role == .Button {
			// A button without a name cannot be operated: its description becomes the name.
			a.name = a.description
		}
		incl[i] = i32(len(ctx.a11y))
		append(&ctx.a11y, a)
	}
}

// Whether the widget's semantics changed since the previous frame, for incremental updates.
@(private)
a11y_same :: proc(a: A11y_Node, b: A11y_Node) -> bool {
	return(
		a.id == b.id &&
		a.parent == b.parent &&
		a.role == b.role &&
		a.name == b.name &&
		a.description == b.description &&
		a.value == b.value &&
		a.rect == b.rect &&
		a.flags == b.flags &&
		a.actions == b.actions \
	)
}

// ---- Logging (MYOD_A11Y_LOG=1) ----

// Prints the semantic tree's changes as text, so a running UI can be inspected without screenshots.
// Called once per presented frame.
@(private)
a11y_log_frame :: proc(ctx: ^Context) {
	if !ctx.a11y_log {
		return
	}
	for &n in ctx.a11y {
		seen := false
		for &old in ctx.a11y_prev {
			if old.id != n.id {
				continue
			}
			seen = true
			if !a11y_same(n, old) {
				fmt.printfln("a11y ~ %s %q %v rect %.0f,%.0f %.0fx%.0f", role_name(n.role), n.name, n.flags, n.rect.x, n.rect.y, n.rect.w, n.rect.h)
			}
		}
		if !seen {
			fmt.printfln("a11y + %s %q %v rect %.0f,%.0f %.0fx%.0f", role_name(n.role), n.name, n.flags, n.rect.x, n.rect.y, n.rect.w, n.rect.h)
		}
	}
	for &old in ctx.a11y_prev {
		found := false
		for &n in ctx.a11y {
			if n.id == old.id {
				found = true
				break
			}
		}
		if !found {
			fmt.printfln("a11y - %s %q", role_name(old.role), old.name)
		}
	}
	// Keep a copy for the next diff. Names point into app or static memory; clone them so a frame's
	// temporary strings do not dangle.
	clear(&ctx.a11y_prev)
	for n in ctx.a11y {
		c := n
		c.name = strings.clone(n.name)
		c.description = strings.clone(n.description)
		c.value = strings.clone(n.value)
		append(&ctx.a11y_prev, c)
	}
}

@(private)
a11y_prev_destroy :: proc(ctx: ^Context) {
	for &n in ctx.a11y_prev {
		delete(n.name)
		delete(n.description)
		delete(n.value)
	}
	delete(ctx.a11y_prev)
}

@(private)
role_name :: proc(r: Role) -> string {
	switch r {
	case .None:        return "none"
	case .Group:       return "group"
	case .Button:      return "button"
	case .Static_Text: return "text"
	case .Image:       return "image"
	case .Textbox:     return "textbox"
	case .Checkbox:    return "checkbox"
	case .Radio:       return "radio"
	case .Slider:      return "slider"
	case .Progress:    return "progress"
	case .Tab:         return "tab"
	case .Tab_Panel:   return "tab-panel"
	case .List:        return "list"
	case .List_Item:   return "list-item"
	case .Menu:        return "menu"
	case .Menu_Item:   return "menu-item"
	case .Dialog:      return "dialog"
	}
	return "none"
}

// Whether MYOD_A11Y_LOG asks for the tree log.
@(private)
a11y_log_enabled :: proc() -> bool {
	v := os.get_env("MYOD_A11Y_LOG", context.temp_allocator)
	return v != "" && v != "0"
}
