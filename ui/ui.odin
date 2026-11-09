// API draft: signatures only, no implementation. It lets examples/ type-check; the real
// implementation replaces it milestone by milestone (see ROADMAP.md). See ARCHITECTURE.md, "API design".
package ui
import "base:intrinsics"

// ---- Windows and the frame loop ----
Window_Options :: struct { title: string, size: [2]int }
Window :: struct { _: rawptr }
open_window :: proc(opts: Window_Options) -> Window { return {} }
close_window :: proc(w: ^Window) {}
next_frame :: proc(w: ^Window) -> bool { return false }
@(deferred_out = _end) window_scope :: proc(w: ^Window) -> bool { return true }

// ---- Store ----
Store :: struct($S, $M: typeid) { state: S, _: rawptr }
Dispatch :: struct($M: typeid) { _: rawptr }
Effects :: struct($M: typeid) { _: rawptr }
store_init :: proc(store: ^Store($S, $M), w: ^Window, state: S, update: proc(s: ^S, msg: M, fx: ^Effects(M)), destroy: proc(s: ^S) = nil) {}
store_destroy :: proc(store: ^Store($S, $M)) {}
dispatcher :: proc(store: ^Store($S, $M)) -> Dispatch(M) { return {} }
dispatch :: proc(d: Dispatch($M), msg: M) {}

// ---- Effects (only callable from update) ----
Task_Id :: distinct u64
Task_Context :: struct($M: typeid) { _: rawptr }
start_task :: proc(fx: ^Effects($M), task: proc(t: ^Task_Context(M), arg: $A) -> M, arg: A) -> Task_Id { return 0 }
cancel_task :: proc(fx: ^Effects($M), id: Task_Id) {}
focus :: proc(fx: ^Effects($M), key: string) {}
emit :: proc(t: ^Task_Context($M), msg: M) {}
cancelled :: proc(t: ^Task_Context($M)) -> bool { return false }

// ---- Low-level primitives for custom stores ----
Inbox :: struct($T: typeid) { _: rawptr }
wake :: proc(w: ^Window) {}

// ---- Layout ----
Icon_Weight :: enum { Thin, Light, Regular, Bold, Fill, Duotone }
Icon :: struct { name: string, svg: [Icon_Weight]string }
Size_Kind :: enum { Fit, Grow, Fixed }
Size :: struct { kind: Size_Kind, value, min, max: f32 }
grow :: proc(min: f32 = 0, max: f32 = max(f32)) -> Size { return {kind = .Grow, min = min, max = max} }
fixed :: proc(v: f32) -> Size { return {kind = .Fixed, value = v} }
Align :: enum { Start, Center, End }
Id :: union { int, string }
Container_Options :: struct { id: Id, width, height: Size, padding, gap: f32, align_x, align_y: Align }
@(deferred_out = _end) column :: proc(o: Container_Options = {}) -> bool { return true }
@(deferred_out = _end) row :: proc(o: Container_Options = {}) -> bool { return true }
@(deferred_out = _end) scroll :: proc(o: Container_Options = {}) -> bool { return true }
@(deferred_out = _end) list_item :: proc(o: Container_Options = {}) -> bool { return true }
_end :: proc(ok: bool) {}
spacer :: proc() {}

// ---- Widgets ----
Rect :: struct { x, y, w, h: f32 }
Response :: struct {
	id: Id, rect: Rect,
	hovered, pressed, clicked, double_clicked: bool,
	changed, submitted, cancelled, focused, lost_focus: bool,
}
Text_Style :: enum { Display, Page_Title, Title, Section, Subsection, Lede, Body, Compact, Label, Metadata }
Color :: enum { Fg, Muted, Faint, Error, Warning, Success, Info }
Button_Variant :: enum { Outline, Primary, Ghost, Danger }
Control_Size :: enum { Default, Small }

text :: proc(s: string, style: Text_Style = .Body, color: Color = .Fg, width: Size = {}) -> Response { return {} }
button :: proc(label: string, icon: Icon = {}, variant: Button_Variant = .Outline, size: Control_Size = .Default, disabled := false) -> Response { return {} }
icon_button :: proc(icon: Icon, label: string, variant: Button_Variant = .Outline, size: Control_Size = .Default, disabled := false) -> Response { return {} }
checkbox :: proc(value: bool, label := "", disabled := false) -> Response { return {} }
text_input :: proc(label: string, value: string, width: Size = {}, hide_label := false, autofocus := false, key := "", error := "") -> (Response, string) { return {}, "" }
tabs :: proc(value: $E, labels: [E]string) -> (Response, E) where intrinsics.type_is_enum(E) { return {}, value }
progress :: proc(value: f32) -> Response { return {} }
tag :: proc(label: string, color: Color = .Muted) -> Response { return {} }
