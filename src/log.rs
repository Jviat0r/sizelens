//! Output goes to the console, or to a log file when running windowless (sizelensw.exe).

use std::io::Write;
use std::sync::{Mutex, OnceLock};

static SINK: OnceLock<Mutex<std::fs::File>> = OnceLock::new();

pub fn to_file(f: std::fs::File) {
    let _ = SINK.set(Mutex::new(f));
}

pub fn is_file() -> bool {
    SINK.get().is_some()
}

pub fn say(msg: &str) {
    if let Some(m) = SINK.get() {
        if let Ok(mut f) = m.lock() {
            for line in msg.lines() {
                let _ = writeln!(f, "{} {}", crate::util::now_iso(), line);
            }
            let _ = f.flush();
        }
    } else {
        println!("{msg}");
    }
}

#[macro_export]
macro_rules! say {
    ($($t:tt)*) => { $crate::log::say(&format!($($t)*)) }
}
