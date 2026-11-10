// API draft for what later milestones implement: signatures only, no implementation. It lets the API
// examples (counter, todomvc, download) type-check; the real implementation replaces it milestone by
// milestone (see ROADMAP.md). See ARCHITECTURE.md, "API design".
package ui

// Windows, the frame loop, the Store, effects and tasks live in window.odin and store.odin.
// The button lives in controls.odin; the text fields in input.odin.
