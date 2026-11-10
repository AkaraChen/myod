// Feedback and identity pages: Toast and Avatar.
package shadcn

import "core:fmt"

import ui "myod:ui"

// ---- Toast ----

@(private)
page_toast :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "toast-basic"})) {
		ui.text("Basic", .Subsection)
		note("Toasts are application state: the stack in the corner is declared by `ui.toast_list`, and every toast is a live region.")
		if ui.row({gap = 8, wrap = true}) {
			if b := ui.button("Show toast"); b.clicked {
				ui.dispatch(d, Toast_Add {
					title = "Scheduled: Friday, November 13 at 3:00 PM",
					description = "The meeting has been added to your calendar.",
				})
			}
			if b := ui.button("Success", variant = .Primary); b.clicked {
				ui.dispatch(d, Toast_Add {
					title = "Changes saved",
					description = "Your profile is up to date.",
					variant = .Success,
				})
			}
			if b := ui.button("Destructive", variant = .Danger); b.clicked {
				ui.dispatch(d, Toast_Add {
					title = "Could not delete the project",
					description = "The project still has deployments attached.",
					variant = .Destructive,
				})
			}
		}
		ui.text(fmt.tprintf("%d toast(s) on screen", len(s.toasts)), .Metadata, .Muted)
	}
	if ui.column(panel({id = "toast-generation"})) {
		ui.text("Auto-dismiss", .Subsection)
		note("Each toast schedules a `ui.after` timer carrying its generation token. A toast dismissed by hand before its timer fires is not removed a second time, and the timer for a newer toast does not remove an older one.")
	}
	if ui.column(panel({id = "toast-states"})) {
		ui.text("States", .Subsection)
		note("Dismiss with the close button or wait five seconds. The close button is reachable with Tab, and the live region announces the toast as it appears.")
	}
}

// ---- Avatar ----

@(private)
page_avatar :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "avatar-basic"})) {
		ui.text("Basic", .Subsection)
		if ui.row({gap = 16, align_y = .Center, wrap = true}) {
			ui.avatar("Ada Lovelace")
			ui.avatar("Grace Hopper", 36)
			ui.avatar("Alan Turing", 44)
			ui.avatar("Edsger W. Dijkstra", 52)
		}
		note("Square, with up to two initials. The size is in logical pixels.")
	}
	if ui.column(panel({id = "avatar-initiatives"})) {
		ui.text("Initials", .Subsection)
		if ui.row({gap = 16, align_y = .Center, wrap = true}) {
			ui.avatar("Ada", 32, "avatar-one-word")
			ui.avatar("mary shelley", 32, "avatar-lower")
			ui.avatar("", 32, "avatar-empty")
		}
		note("One word gives one letter, lower case is upper-cased, and an empty name shows a person glyph.")
	}
	if ui.column(panel({id = "avatar-states"})) {
		ui.text("States", .Subsection)
		note("Avatars take focus and a hover border; screen readers get the full name as the image's label.")
	}
}
