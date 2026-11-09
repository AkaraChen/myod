#+build !darwin
// Nothing to hook up on the other platforms yet (AT-SPI joins with the Linux port).
package core

import "../platform"

a11y_attach :: proc(ctx: ^Context, p: ^platform.Window) {}

a11y_detach :: proc(ctx: ^Context) {}

a11y_window_focus :: proc(ctx: ^Context, focused: bool) {}

a11y_publish :: proc(ctx: ^Context, scale: f32, physical: [2]u32) {}
