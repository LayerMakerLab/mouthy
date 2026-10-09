//! Portable Mouthy core for the Windows and Linux app: text rules, modes and settings.
//! The Mac app implements the same rules in Swift; `shared/text-rules.json` keeps them identical.

pub mod code;
pub mod modes;
pub mod text;

pub use code::*;
pub use modes::*;
pub use text::*;
