//! JapuszkoInjector core: Apple ID sign-in, signing and installing on top of
//! `isideload` + `idevice`, plus the app registry and refresh logic.

pub mod device;
pub mod engine;
pub mod ffi;
pub mod guest;
pub mod model;
pub mod prep;

pub use engine::Engine;
