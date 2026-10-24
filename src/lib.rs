//! SizeLens: puts folder sizes into Windows File Explorer's "Comments" column.
//!
//! How: the folders under each opted-in folder (every level, see `depth`) get a `desktop.ini` with
//! `[.ShellClassInfo] InfoTip=<size>`. Explorer shows a folder's InfoTip as its
//! System.Comment property ("Comments" column, and the hover tooltip), but only reads
//! desktop.ini when the folder has the Read-only or System attribute.
//! Everything SizeLens changes is recorded so `sizelens clean` can put it back.

pub mod log;
pub mod util;
pub mod win;
pub mod config;
pub mod fmt;
pub mod ini;
pub mod safety;
pub mod store;
pub mod scan;
pub mod apply;
pub mod watch;
pub mod followup;
pub mod cli;
