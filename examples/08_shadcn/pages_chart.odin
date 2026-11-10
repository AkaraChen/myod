// Chart pages: bar, line, area, pie and radar. The marks are rasterized into one texture per
// (data version, pixel size); labels, legends and the hover overlay are normal widgets on top.
package shadcn

import "core:fmt"

import chart "myod:chart"
import core "myod:core"
import ui "myod:ui"

@(private)
CHART_MONTHS := []string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

@(private)
BARS_A := []f32{186, 305, 237, 73, 209, 214, 250, 190, 220, 280, 240, 300}
@(private)
BARS_B := []f32{120, 260, 300, 140, 180, 260, 210, 240, 260, 220, 300, 280}

@(private)
LINES_A := []f32{120, 180, 160, 260, 230, 310, 280, 340, 300, 380, 350, 420}
@(private)
LINES_B := []f32{80, 130, 150, 170, 200, 210, 260, 250, 300, 290, 330, 360}

// The charts switch between two static data sets with the data version, so the "New data" button
// exercises the re-rasterization path.
@(private)
chart_set :: proc(version: u64) -> (a, b: []f32) {
	if (version & 1) == 0 {
		return BARS_B, LINES_B
	}
	return BARS_A, LINES_A
}

@(private)
chart_controls :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.row({gap = 10, align_y = .Center}) {
		if b := ui.button("New data", variant = .Outline, size = .Small); b.clicked {
			ui.dispatch(d, Chart_Bump{})
		}
		ui.text(fmt.tprintf("Data version %d", s.chart_version), .Metadata, .Faint)
	}
}

@(private)
chart_series :: proc(a, b: []f32) -> []chart.Series {
	series := make([]chart.Series, 2, context.temp_allocator)
	series[0] = chart.Series{label = "Desktop", values = a, color = core.Token.Info}
	series[1] = chart.Series{label = "Mobile", values = b, color = core.Token.Success}
	return series
}

// ---- Bar ----

@(private)
page_chart_bar :: proc(s: State, d: ui.Dispatch(Msg)) {
	a, b := chart_set(s.chart_version)
	if ui.column(panel({id = "chart-bar-basic"})) {
		ui.text("Basic", .Subsection)
		chart_controls(s, d)
		res := chart.bar_chart({
			id      = "bar-basic",
			labels  = CHART_MONTHS,
			series  = chart_series(a, b),
			width   = ui.grow(),
			height  = ui.fixed(300),
			version = s.chart_version,
			legend  = true,
		})
		note(res.hover >= 0 ? fmt.tprintf("Hovering %s", CHART_MONTHS[res.hover]) : "Hover a category for its values.")
	}
	if ui.column(panel({id = "chart-bar-stacked"})) {
		ui.text("Stacked", .Subsection)
		chart.bar_chart({
			id      = "bar-stacked",
			labels  = CHART_MONTHS,
			series  = chart_series(a, b),
			width   = ui.grow(),
			height  = ui.fixed(280),
			version = s.chart_version,
			legend  = true,
			stacked = true,
		})
	}
}

// ---- Line ----

@(private)
page_chart_line :: proc(s: State, d: ui.Dispatch(Msg)) {
	a, b := chart_set(s.chart_version)
	if ui.column(panel({id = "chart-line-basic"})) {
		ui.text("Basic", .Subsection)
		chart_controls(s, d)
		res := chart.line_chart({
			id      = "line-basic",
			labels  = CHART_MONTHS,
			series  = chart_series(a, b),
			width   = ui.grow(),
			height  = ui.fixed(300),
			version = s.chart_version,
			legend  = true,
		})
		note(res.hover >= 0 ? fmt.tprintf("Hovering %s", CHART_MONTHS[res.hover]) : "The crosshair and tooltip are widgets over the texture; hovering never re-rasterizes.")
	}
	if ui.column(panel({id = "chart-line-plain"})) {
		ui.text("Without a grid or legend", .Subsection)
		chart.line_chart({
			id      = "line-plain",
			labels  = CHART_MONTHS,
			series  = chart_series(a, b),
			width   = ui.grow(),
			height  = ui.fixed(240),
			version = s.chart_version,
			no_grid = true,
		})
	}
}

// ---- Area ----

@(private)
page_chart_area :: proc(s: State, d: ui.Dispatch(Msg)) {
	a, b := chart_set(s.chart_version)
	if ui.column(panel({id = "chart-area-basic"})) {
		ui.text("Basic", .Subsection)
		chart_controls(s, d)
		chart.area_chart({
			id      = "area-basic",
			labels  = CHART_MONTHS,
			series  = chart_series(a, b),
			width   = ui.grow(),
			height  = ui.fixed(300),
			version = s.chart_version,
			legend  = true,
		})
	}
	if ui.column(panel({id = "chart-area-stacked"})) {
		ui.text("Stacked", .Subsection)
		chart.area_chart({
			id      = "area-stacked",
			labels  = CHART_MONTHS,
			series  = chart_series(a, b),
			width   = ui.grow(),
			height  = ui.fixed(280),
			version = s.chart_version,
			legend  = true,
			stacked = true,
		})
	}
}

// ---- Pie ----

@(private)
BROWSER_LABELS := []string{"Chrome", "Safari", "Firefox", "Edge", "Other"}
@(private)
BROWSER_VALUES := []f32{275, 200, 187, 173, 90}
@(private)
BROWSER_VALUES_B := []f32{300, 180, 160, 200, 120}

@(private)
page_chart_pie :: proc(s: State, d: ui.Dispatch(Msg)) {
	values := BROWSER_VALUES
	if (s.chart_version & 1) == 0 {
		values = BROWSER_VALUES_B
	}
	if ui.column(panel({id = "chart-pie-basic"})) {
		ui.text("Pie", .Subsection)
		chart_controls(s, d)
		res := chart.pie_chart({
			id      = "pie-basic",
			labels  = BROWSER_LABELS,
			values  = values,
			width   = ui.grow(),
			height  = ui.fixed(300),
			version = s.chart_version,
			legend  = true,
		})
		note(res.hover >= 0 ? fmt.tprintf("Hovering %s", BROWSER_LABELS[res.hover]) : "Hover a slice for its label, value and share.")
	}
	if ui.column(panel({id = "chart-pie-donut"})) {
		ui.text("Donut", .Subsection)
		chart.pie_chart({
			id      = "pie-donut",
			labels  = BROWSER_LABELS,
			values  = values,
			width   = ui.grow(),
			height  = ui.fixed(280),
			version = s.chart_version,
			legend  = true,
			donut   = 0.62,
		})
	}
}

// ---- Radar ----

@(private)
RADAR_LABELS := []string{"Speed", "Reliability", "Comfort", "Safety", "Efficiency", "Price"}

@(private)
RADAR_A := []f32{80, 90, 70, 85, 75, 60}
@(private)
RADAR_B := []f32{60, 80, 90, 70, 85, 90}
@(private)
RADAR_A2 := []f32{90, 75, 80, 70, 60, 80}
@(private)
RADAR_B2 := []f32{70, 85, 75, 90, 80, 70}

@(private)
radar_series :: proc(version: u64) -> []chart.Series {
	series := make([]chart.Series, 2, context.temp_allocator)
	a, b := RADAR_A, RADAR_B
	if (version & 1) == 0 {
		a, b = RADAR_A2, RADAR_B2
	}
	series[0] = chart.Series{label = "Model A", values = a, color = core.Token.Info}
	series[1] = chart.Series{label = "Model B", values = b, color = core.Token.Warning}
	return series
}

@(private)
page_chart_radar :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "chart-radar-basic"})) {
		ui.text("Basic", .Subsection)
		chart_controls(s, d)
		res := chart.radar_chart({
			id      = "radar-basic",
			labels  = RADAR_LABELS,
			series  = radar_series(s.chart_version),
			width   = ui.grow(),
			height  = ui.fixed(340),
			version = s.chart_version,
			legend  = true,
		})
		note(res.hover >= 0 ? fmt.tprintf("Hovering %s", RADAR_LABELS[res.hover]) : "Hover a spoke to compare every series on that axis.")
	}
	if ui.column(panel({id = "chart-radar-rings"})) {
		ui.text("More rings, fixed maximum", .Subsection)
		chart.radar_chart({
			id      = "radar-rings",
			labels  = RADAR_LABELS,
			series  = radar_series(s.chart_version),
			width   = ui.grow(),
			height  = ui.fixed(300),
			version = s.chart_version,
			max     = 100,
			rings   = 5,
		})
	}
}
