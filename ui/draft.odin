// API draft for what later milestones implement: signatures only, no implementation. It lets the API
// examples (counter, todomvc, download) type-check; the real implementation replaces it milestone by
// milestone (see ROADMAP.md). See ARCHITECTURE.md, "API design".
package ui

import "base:intrinsics"

// Windows, the frame loop, the Store, effects and tasks live in window.odin and store.odin.
// The button lives in controls.odin.

// ---- Widgets ----
checkbox :: proc(value: bool, label := "", disabled := false) -> Response { return {} }
text_input :: proc(label: string, value: string, width: Size = {}, hide_label := false, autofocus := false, key := "", error := "") -> (Response, string) { return {}, "" }
tabs :: proc(value: $E, labels: [E]string) -> (Response, E) where intrinsics.type_is_enum(E) { return {}, value }
progress :: proc(value: f32) -> Response { return {} }
tag :: proc(label: string, color: Color = .Muted) -> Response { return {} }
