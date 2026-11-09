//! myod's Rust dependencies behind a C ABI: Taffy layout (see `layout`) and AccessKit (see `a11y`).
//!
//! Built as a static library with `panic = "abort"`; nothing here may unwind across the C ABI.

pub mod layout;
pub mod a11y;
