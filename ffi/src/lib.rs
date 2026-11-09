//! myod's Rust dependencies behind a C ABI. For now: Taffy layout (see `layout`).
//!
//! Built as a static library with `panic = "abort"`; nothing here may unwind across the C ABI.

pub mod layout;
