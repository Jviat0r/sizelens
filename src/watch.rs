//! Watch mode: keep sizes current with almost no CPU.
//!
//! One blocking ReadDirectoryChangesW per root (recursive) tells us which top-level subfolder
//! changed; that subfolder is re-measured once things go quiet for `debounce_seconds`.
//! A full re-scan runs every `full_rescan_minutes` to catch anything missed (and right away if
//! Windows reports the change buffer overflowed). The process runs at background priority.
//! It also does the follow-up rewrites that let already-open Explorer windows catch up (followup.rs).

use crate::config::{self, Config};
use crate::scan::{self, ScanOptions};
use crate::util::{data_dir, key};
use crate::win::{self, Change, DirWatch, NamedMutex};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime};

/// One watcher per data folder: Local\SizeLens.Watch, plus a suffix when SIZELENS_HOME points elsewhere
/// (so a test watcher and the real one don't block each other).
pub fn mutex_name() -> String {
    format!("Local\\SizeLens.Watch{}", crate::util::instance_suffix())
}

pub fn stop_flag() -> PathBuf {
    data_dir().join("stop.flag")
}

pub fn is_running() -> bool {
    match NamedMutex::claim(&mutex_name()) {
        Some(_m) => false, // we could take it, so nobody holds it (dropped right away)
        None => true,
    }
}

enum Msg {
    Sub(String, String), // root key, subfolder name
    All(String),         // root key: rescan everything
}

fn spawn_watcher(root: PathBuf, tx: mpsc::Sender<Msg>) {
    std::thread::spawn(move || {
        let rk = key(&root);
        let mut w = match DirWatch::open(&root) {
            Ok(w) => w,
            Err(e) => {
                crate::say!("watch: {e}");
                return;
            }
        };
        loop {
            match w.next_batch() {
                Ok(changes) => {
                    for c in changes {
                        let msg = match c {
                            Change::Overflow => Msg::All(rk.clone()),
                            Change::Path(rel) => {
                                let parts: Vec<&str> = rel.split('\\').filter(|s| !s.is_empty()).collect();
                                if parts.is_empty() {
                                    continue;
                                }
                                // Our own writes: ...\desktop.ini at any level. Ignore them, or we would loop.
                                if parts.len() >= 2 && parts[parts.len() - 1].eq_ignore_ascii_case("desktop.ini") {
                                    continue;
                                }
                                Msg::Sub(rk.clone(), parts[0].to_string())
                            }
                        };
                        if tx.send(msg).is_err() {
                            return;
                        }
                    }
                }
                Err(e) => {
                    crate::say!("watch: stopped watching {}: {e}", root.display());
                    let _ = tx.send(Msg::All(rk.clone()));
                    return;
                }
            }
        }
    });
}

fn config_mtime() -> Option<SystemTime> {
    std::fs::metadata(config::path()).and_then(|m| m.modified()).ok()
}

pub fn run() -> Result<(), String> {
    let _single = NamedMutex::claim(&mutex_name()).ok_or("a SizeLens watcher is already running")?;
    win::background_priority();
    let _ = std::fs::remove_file(stop_flag());

    let mut cfg = Config::load()?;
    let mut cfg_time = config_mtime();
    crate::say!(
        "SizeLens watch: {} root(s), debounce {} s, full re-scan every {} min. Stop with `sizelens stop`.",
        cfg.roots.len(),
        cfg.debounce_secs,
        cfg.full_rescan_minutes
    );

    let (tx, rx) = mpsc::channel::<Msg>();
    let mut watched: HashSet<String> = HashSet::new();
    let mut last_full = Instant::now() - Duration::from_secs(365 * 24 * 3600);
    // root key -> subfolder name (lowercase) -> (first event, last event, original name)
    let mut dirty: HashMap<String, HashMap<String, (Instant, Instant, String)>> = HashMap::new();
    let mut full_pending: HashSet<String> = HashSet::new();

    loop {
        // Start watchers for any new roots.
        for r in &cfg.roots {
            let k = key(&r.path);
            if !watched.contains(&k) && r.path.is_dir() {
                spawn_watcher(r.path.clone(), tx.clone());
                watched.insert(k);
            }
        }

        // Periodic full re-scan.
        if last_full.elapsed() >= Duration::from_secs(cfg.full_rescan_minutes * 60) {
            for r in &cfg.roots {
                full_pending.insert(key(&r.path));
            }
            last_full = Instant::now();
        }
        for rk in std::mem::take(&mut full_pending) {
            if let Some(r) = cfg.roots.iter().find(|r| key(&r.path) == rk) {
                let opt = ScanOptions { dry_run: false, only: None, threads: 1 };
                match scan::scan_root(&cfg, r, &opt) {
                    Ok(rep) => {
                        let n = rep.items.iter().filter(|i| i.action == "updated").count();
                        crate::say!("full scan {}: {} folders, {} updated", r.path.display(), rep.items.len(), n);
                        for i in rep.items.iter().filter(|i| i.action.starts_with("error")) {
                            crate::say!("  {}: {}", i.name, i.action);
                        }
                    }
                    Err(e) => crate::say!("full scan {}: {e}", r.path.display()),
                }
                dirty.remove(&rk);
            }
        }

        // Collect events for up to 1 s.
        match rx.recv_timeout(Duration::from_secs(1)) {
            Ok(m) => {
                let mut handle = |m: Msg| match m {
                    Msg::All(rk) => {
                        full_pending.insert(rk);
                    }
                    Msg::Sub(rk, name) => {
                        let now = Instant::now();
                        let e = dirty.entry(rk).or_default().entry(name.to_lowercase()).or_insert((now, now, name));
                        e.1 = now;
                    }
                };
                handle(m);
                while let Ok(m) = rx.try_recv() {
                    handle(m);
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {}
        }

        // Re-measure subfolders that have been quiet for debounce_secs (or busy for 5 min).
        let quiet = Duration::from_secs(cfg.debounce_secs);
        let busy_cap = Duration::from_secs(300);
        let roots_dirty: Vec<String> = dirty.keys().cloned().collect();
        for rk in roots_dirty {
            let subs = dirty.get_mut(&rk).unwrap();
            let ready: Vec<String> = subs
                .iter()
                .filter(|(_, (first, last, _))| last.elapsed() >= quiet || first.elapsed() >= busy_cap)
                .map(|(k, _)| k.clone())
                .collect();
            if ready.is_empty() {
                continue;
            }
            let names: Vec<String> = ready.iter().filter_map(|k| subs.remove(k).map(|v| v.2)).collect();
            if let Some(r) = cfg.roots.iter().find(|r| key(&r.path) == rk) {
                let opt = ScanOptions { dry_run: false, only: Some(&names), threads: 1 };
                match scan::scan_root(&cfg, r, &opt) {
                    Ok(rep) => {
                        for i in &rep.items {
                            if i.action != "unchanged" {
                                crate::say!("{}\\{} -> {} ({})", r.path.display(), i.name, i.tip, i.action);
                            }
                        }
                        for p in &rep.removed {
                            crate::say!("forgot {p} (folder removed)");
                        }
                    }
                    Err(e) => crate::say!("scan {}: {e}", r.path.display()),
                }
            }
        }
        dirty.retain(|_, m| !m.is_empty());

        // Follow-up rewrites that are due (open Explorer windows catch up; see followup.rs).
        match crate::followup::run_due() {
            Ok(0) => {}
            Ok(n) => crate::say!("follow-up: rewrote {n} label(s) so open Explorer windows show them"),
            Err(e) => crate::say!("follow-up: {e}"),
        }

        // Stop request?
        if stop_flag().exists() {
            let _ = std::fs::remove_file(stop_flag());
            crate::say!("SizeLens watch: stop requested, exiting.");
            return Ok(());
        }

        // Config edited (roots added/removed, format changed)? Reload and re-scan everything.
        let t = config_mtime();
        if t != cfg_time {
            cfg_time = t;
            match Config::load() {
                Ok(c) => {
                    crate::say!("config.txt changed: reloading ({} root(s)).", c.roots.len());
                    cfg = c;
                    for r in &cfg.roots {
                        full_pending.insert(key(&r.path));
                    }
                }
                Err(e) => crate::say!("config.txt has an error, keeping the old settings: {e}"),
            }
        }
    }
}
