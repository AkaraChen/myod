// Form pages: Field, Input OTP, Calendar and Date Picker.
package shadcn

import "core:fmt"

import ui "myod:ui"

// ---- Field ----

@(private)
page_field :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "field-basic"})) {
		ui.text("Basic", .Subsection)
		if f := ui.field("Email", "We will never share your email with anyone.", "", "field-email"); f.open {
			if r, v := ui.text_input("Email", s.field_email, key = "field-email", hide_label = true); r.changed {
				ui.dispatch(d, Field_Set{v})
			}
		}
		if f := ui.field("Bio", "You can @mention other users and organizations.", "", "field-bio"); f.open {
			if r, v := ui.text_area("Bio", s.field_bio, 3, key = "field-bio", hide_label = true); r.changed {
				ui.dispatch(d, Bio_Set{v})
			}
		}
	}
	if ui.column(panel({id = "field-error"})) {
		ui.text("Error", .Subsection)
		note("The error replaces the description, turns the label red and is announced with the field.")
		invalid := s.field_account != "" && !valid_account(s.field_account)
		if f := ui.field("Account name", "", invalid ? "Account names may not contain spaces or the @ sign." : "", "field-account"); f.open {
			if r, v := ui.text_input(
				"Account name",
				s.field_account != "" ? s.field_account : "ada",
				key = "field-account",
				hide_label = true,
				error = invalid ? "Use letters, digits and dashes." : "",
			); r.changed {
				ui.dispatch(d, Account_Set{v})
			}
		}
	}
	if ui.column(panel({id = "field-disabled"})) {
		ui.text("Disabled", .Subsection)
		if f := ui.field("Workspace", "The workspace cannot be renamed.", "", "field-workspace"); f.open {
			if r, v := ui.text_input("Workspace", "myod", key = "field-workspace", hide_label = true, disabled = true); r.changed {
				_ = v
			}
		}
	}
}

// Letters, digits and dashes only.
@(private)
valid_account :: proc(s: string) -> bool {
	for c in s {
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

// ---- Input OTP ----

@(private)
page_input_otp :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "otp-basic"})) {
		ui.text("Basic", .Subsection)
		note("One digit per cell. Typing fills the current cell and advances; Backspace on an empty cell moves back; Left/Right move.")
		if _, v := ui.input_otp(s.otp, 6, "otp-demo"); v != s.otp {
			ui.dispatch(d, Otp_Set{v})
		}
		ui.text(
			s.otp == "" ? "No code yet" : fmt.tprintf("Code: %s", s.otp),
			.Metadata,
			.Muted,
		)
	}
	if ui.column(panel({id = "otp-disabled"})) {
		ui.text("Disabled", .Subsection)
		ui.input_otp("123456", 6, "otp-disabled", disabled = true)
	}
	if ui.column(panel({id = "otp-partial"})) {
		ui.text("Partial", .Subsection)
		ui.input_otp("42", 6, "otp-partial")
	}
}

// ---- Calendar ----

@(private)
page_calendar :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "calendar-basic"})) {
		ui.text("Basic", .Subsection)
		cr := ui.calendar(s.cal_month, s.cal_date, "calendar-demo")
		if cr.month != s.cal_month || cr.date != s.cal_date {
			ui.dispatch(d, Calendar_Set{cr.month, cr.date})
		}
		ui.text(fmt.tprintf("Selected: %s", ui.date_format(s.cal_date)), .Metadata, .Muted)
	}
	if ui.column(panel({id = "calendar-keyboard"})) {
		ui.text("Keyboard", .Subsection)
		note("Tab reaches the grid; arrows move by a day or a week, across month boundaries; Enter picks the focused day.")
	}
}

// ---- Date Picker ----

@(private)
page_date_picker :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "date-picker-basic"})) {
		ui.text("Basic", .Subsection)
		if _, v := ui.date_picker(s.date_value, "date-picker-demo", ui.fixed(200)); v != s.date_value {
			ui.dispatch(d, Date_Set{v})
		}
		ui.text(fmt.tprintf("Value: %s", ui.date_format(s.date_value)), .Metadata, .Muted)
	}
	if ui.column(panel({id = "date-picker-empty"})) {
		ui.text("No value", .Subsection)
		note("An empty Date shows the placeholder; picking a day closes the popover and returns focus to the trigger.")
		if _, v := ui.date_picker({}, "date-picker-empty", ui.fixed(200)); v.year != 0 {
			ui.dispatch(d, Date_Set{v})
		}
	}
}
