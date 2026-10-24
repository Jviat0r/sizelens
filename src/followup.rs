//! Follow-up rewrites, so File Explorer windows that are already open catch up with a new size.
//!
//! Measured on Windows 10 22H2 (TEST-REPORT.md, round 3): an open Explorer window ignores a
//! desktop.ini change that happens within about 60 s after the window last read that file. F5,
//! SHChangeNotify, re-navigating the window to the same folder, or to its parent and back, don't get
//! past it; a newly opened window does read the new value. A write that comes later than that is
//! picked up on the next notification.
//!
//! So after SizeLens changes a folder's label it schedules one more write of the same bytes
//! `follow_up_seconds` later (default 65). Each new change of that folder moves its follow-up back,
//! so a burst of changes ends with exactly one follow-up. The watcher runs the due follow-ups; when no
//! watcher is running, a one-off scan starts a hidden helper (`sizelensw.exe follow-up`) that does
//! them and exits.
//!
//! followup.tsv in the data folder holds the pending ones: `due_unix_seconds <tab> folder`.

use crate::apply;
use crate::store;
use crate::util::{data_dir, key, write_atomic, Lock};
use crate::win::{self, NamedMutex};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn helper_mutex() -> String {
    format!("Local\\SizeLens.FollowUp{}", crate::util::instance_suffix())
}

pub fn path() -> PathBuf {
    data_dir().join("followup.tsv")
}

pub fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// folder key -> (due time, folder)
pub fn load() -> BTreeMap<String, (u64, PathBuf)> {
    let mut m = BTreeMap::new();
    let Ok(text) = std::fs::read_to_string(path()) else {
        return m;
    };
    for l in text.lines() {
        if l.starts_with('#') || l.trim().is_empty() {
            continue;
        }
        if let Some((due, p)) = l.split_once('\t') {
            if let Ok(d) = due.trim().parse::<u64>() {
                let p = PathBuf::from(p);
                m.insert(key(&p), (d, p));
            }
        }
    }
    m
}

fn save(m: &BTreeMap<String, (u64, PathBuf)>) -> Result<(), String> {
    if m.is_empty() {
        return match std::fs::remove_file(path()) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("can't update followup.tsv: {e}")),
        };
    }
    let mut s = String::from("# SizeLens follow-up rewrites (so open Explorer windows catch up). due_unix_seconds\tfolder\r\n");
    for (due, p) in m.values() {
        s.push_str(&format!("{due}\t{}\r\n", p.display()));
    }
    write_atomic(&path(), s.as_bytes()).map_err(|e| format!("can't save followup.tsv: {e}"))
}

/// Schedule a follow-up for these folders `delay` seconds from now (0 = off). Call with the Lock held.
pub fn schedule_locked(folders: &[PathBuf], delay: u64) -> Result<(), String> {
    if delay == 0 || folders.is_empty() {
        return Ok(());
    }
    let mut m = load();
    let due = now_secs() + delay;
    for f in folders {
        m.insert(key(f), (due, f.clone()));
    }
    save(&m)
}

/// Seconds until the next follow-up is due (0 = now), or None when nothing is pending.
pub fn next_due_in() -> Option<u64> {
    let now = now_secs();
    load().values().map(|(d, _)| d.saturating_sub(now)).min()
}

/// Do every follow-up that is due. Returns how many folders were rewritten.
pub fn run_due() -> Result<usize, String> {
    let now = now_secs();
    if !load().values().any(|(d, _)| *d <= now) {
        return Ok(0);
    }
    let _lock = Lock::acquire()?;
    let mut pending = load(); // again, under the lock
    let man = store::load_managed();
    let due: Vec<String> = pending.iter().filter(|(_, (d, _))| *d <= now).map(|(k, _)| k.clone()).collect();
    let mut done = 0;
    let mut parents: BTreeMap<String, PathBuf> = BTreeMap::new();
    for k in due {
        let Some((_, folder)) = pending.remove(&k) else { continue };
        let Some(m) = man.get(&k) else { continue }; // cleaned since: nothing to do
        match apply::rewrite_same(&folder, m) {
            Ok(true) => {
                done += 1;
                if let Some(p) = folder.parent() {
                    parents.insert(key(p), p.to_path_buf());
                }
            }
            Ok(false) => {}
            Err(e) => crate::say!("follow-up {}: {e}", folder.display()),
        }
    }
    save(&pending)?;
    for p in parents.values() {
        if p.is_dir() {
            win::notify_dir(p, true);
        }
    }
    Ok(done)
}

/// After a one-off scan: if no watcher is running, start the hidden helper that does the follow-ups.
pub fn ensure_handled() {
    if load().is_empty() || crate::watch::is_running() {
        return;
    }
    use std::os::windows::process::CommandExt;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let Ok(me) = std::env::current_exe() else { return };
    let w = me.with_file_name("sizelensw.exe");
    let (exe, flags) = if w.is_file() {
        (w, DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP)
    } else {
        (me, CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP)
    };
    win::std_handles_not_inheritable();
    let r = std::process::Command::new(&exe)
        .arg("follow-up")
        .current_dir(exe.parent().unwrap_or(Path::new(".")))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .creation_flags(flags)
        .spawn();
    if let Err(e) = r {
        crate::say!("could not start the follow-up helper ({e}); a later scan or the watcher will do it");
    }
}

/// `sizelens follow-up`: wait for and do the pending follow-ups, then exit. One helper at a time;
/// it also stops early if a watcher starts (the watcher takes over).
pub fn run_helper() -> i32 {
    // A helper that is about to exit may still hold the mutex for a moment: retry briefly.
    let mut held = None;
    for _ in 0..20 {
        held = NamedMutex::claim(&helper_mutex());
        if held.is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let Some(mutex) = held else { return 0 };
    win::background_priority();
    let mut mutex = Some(mutex);
    loop {
        if crate::watch::is_running() {
            return 0;
        }
        if let Err(e) = run_due() {
            crate::say!("follow-up: {e}");
        }
        match next_due_in() {
            Some(s) => std::thread::sleep(Duration::from_secs(s.clamp(1, 5))),
            None => {
                // Let go, then look once more: a scan may have added one after we read the file.
                drop(mutex.take());
                std::thread::sleep(Duration::from_millis(300));
                if load().is_empty() {
                    return 0;
                }
                match NamedMutex::claim(&helper_mutex()) {
                    Some(m) => mutex = Some(m),
                    None => return 0, // another helper has it now
                }
            }
        }
    }
}
