use crate::config::{self, Config, Root};
use crate::fmt;
use crate::safety;
use crate::scan::{self, ScanOptions};
use crate::store;
use crate::util::{data_dir, is_under, key, norm_path};
use crate::watch;
use std::path::{Path, PathBuf};

const HELP: &str = "SizeLens - folder sizes in File Explorer's Comments column

Usage: sizelens <command> [options]

  add <folder> [--allow-onedrive] [--allow-drive-root]
        Opt a folder in (adds a root line to config.txt). Its subfolders get sizes on the next scan.
  scan <folder> | --all [--dry-run] [--verbose]
        Measure every folder under an opted-in folder (to `depth` in config.txt, default all levels)
        and write each one's size into its desktop.ini (InfoTip). Only changed sizes are rewritten.
  here <folder> [--pause]
        add + scan in one go (what the Explorer right-click \"Show or refresh folder sizes\" runs).
        A folder inside one that is already opted in is just re-measured, not opted in again.
  clean <folder> | --all [--keep-root] [--pause]
        Undo everything SizeLens did there: restore backed-up desktop.ini files exactly, delete the
        ones it created, put folder attributes back. Also opts the folder out (unless --keep-root).
  status
        Opted-in folders, last scan, biggest subfolders, watcher state, file locations.
  watch
        Stay running and keep sizes current (low priority; stop with `sizelens stop`).
  stop
        Ask a running watcher to exit.
  fmt <bytes>...
        Show how sizes are written in each format.

Explorer: right-click a column header > More... > tick Comments (or install.ps1 -AddCommentsColumn).
An Explorer window that is already open shows a new size within about a minute (SizeLens writes each
changed label once more after follow_up_seconds); a newly opened window shows it right away.
";

struct Args {
    cmd: String,
    pos: Vec<String>,
    flags: Vec<String>,
}

fn parse(argv: &[String]) -> Args {
    let mut a = Args { cmd: String::new(), pos: Vec::new(), flags: Vec::new() };
    for (i, s) in argv.iter().enumerate() {
        if i == 0 {
            a.cmd = s.to_ascii_lowercase();
        } else if s.starts_with("--") {
            a.flags.push(s.to_ascii_lowercase());
        } else {
            a.pos.push(s.clone());
        }
    }
    a
}

impl Args {
    fn has(&self, f: &str) -> bool {
        self.flags.iter().any(|x| x == f)
    }
}

/// Explorer's %V can arrive with a trailing quote or backslash ("D:\Foo\"); tidy it.
fn folder_arg(s: &str) -> Result<PathBuf, String> {
    let t = s.trim().trim_matches('"');
    if t.is_empty() {
        return Err("no folder given".into());
    }
    norm_path(Path::new(t)).map_err(|e| format!("bad folder '{t}': {e}"))
}

/// Exit codes: 0 ok, 1 error, 2 refused (safety rule or not opted in), 3 usage.
pub fn run(argv: &[String]) -> i32 {
    let a = parse(argv);
    let pause = a.has("--pause");
    let code = match a.cmd.as_str() {
        "" | "help" | "-h" | "--help" | "/?" => {
            crate::say!("{HELP}");
            0
        }
        "add" => cmd_add(&a),
        "scan" => cmd_scan(&a),
        "here" => cmd_here(&a),
        "follow-up" => crate::followup::run_helper(),
        "clean" | "remove" => cmd_clean(&a),
        "status" => cmd_status(),
        "watch" => match watch::run() {
            Ok(()) => 0,
            Err(e) => {
                crate::say!("error: {e}");
                1
            }
        },
        "stop" => cmd_stop(),
        "fmt" => cmd_fmt(&a),
        "paths" => {
            crate::say!("data folder: {}", data_dir().display());
            0
        }
        other => {
            crate::say!("unknown command '{other}'\n\n{HELP}");
            3
        }
    };
    if pause && !crate::log::is_file() {
        use std::io::Read;
        if code == 0 {
            crate::say!("\nDone. A window that was already open shows the new sizes within about a minute. Closing in 5 s...");
            std::thread::sleep(std::time::Duration::from_secs(5));
        } else {
            crate::say!("\nPress Enter to close.");
            let _ = std::io::stdin().read(&mut [0u8]);
        }
    }
    code
}

fn cmd_add(a: &Args) -> i32 {
    let Some(p) = a.pos.first() else {
        crate::say!("usage: sizelens add <folder>");
        return 3;
    };
    let path = match folder_arg(p) {
        Ok(p) => p,
        Err(e) => {
            crate::say!("error: {e}");
            return 1;
        }
    };
    // A junction/symlink given directly: refuse rather than silently opting in its target.
    if let Ok(raw) = std::path::absolute(Path::new(p.trim().trim_matches('"'))) {
        if let Ok(a) = crate::win::get_attrs(&raw) {
            if a & crate::win::ATTR_REPARSE != 0 {
                crate::say!(
                    "refused: {} is a link (junction or symlink). Add the real folder instead: {}",
                    raw.display(),
                    path.display()
                );
                return 2;
            }
        }
    }
    let root = Root {
        path: path.clone(),
        allow_onedrive: a.has("--allow-onedrive"),
        allow_drive_root: a.has("--allow-drive-root"),
    };
    let mut cfg = match Config::load() {
        Ok(c) => c,
        Err(e) => {
            crate::say!("error: {e}");
            return 1;
        }
    };
    // Keep flags that were already in config.txt for this folder.
    let root = match cfg.find_root(&path) {
        Some(existing) => Root {
            path: path.clone(),
            allow_onedrive: root.allow_onedrive || existing.allow_onedrive,
            allow_drive_root: root.allow_drive_root || existing.allow_drive_root,
        },
        None => root,
    };
    if let Err(why) = safety::check_root(&root.path, root.allow_onedrive, root.allow_drive_root) {
        crate::say!("refused: {}: {why}", path.display());
        return 2;
    }
    if cfg.find_root(&path).is_some() {
        crate::say!("{} is already opted in.", path.display());
        return 0;
    }
    match cfg.add_root(root) {
        Ok(()) => {
            crate::say!("opted in: {}  (config: {})", path.display(), config::path().display());
            0
        }
        Err(e) => {
            crate::say!("error: {e}");
            1
        }
    }
}

fn cmd_scan(a: &Args) -> i32 {
    let cfg = match Config::load() {
        Ok(c) => c,
        Err(e) => {
            crate::say!("error: {e}");
            return 1;
        }
    };
    let roots: Vec<Root> = if a.has("--all") {
        cfg.roots.clone()
    } else {
        let Some(p) = a.pos.first() else {
            crate::say!("usage: sizelens scan <folder> | --all");
            return 3;
        };
        let path = match folder_arg(p) {
            Ok(p) => p,
            Err(e) => {
                crate::say!("error: {e}");
                return 1;
            }
        };
        match cfg.find_root(&path) {
            Some(r) => vec![r.clone()],
            None => {
                crate::say!(
                    "refused: {} is not opted in. Run `sizelens add \"{}\"` first (or use `sizelens here`).",
                    path.display(),
                    path.display()
                );
                return 2;
            }
        }
    };
    if roots.is_empty() {
        crate::say!("No folders opted in yet. Use `sizelens add <folder>`.");
        return 0;
    }
    run_scans(&cfg, &roots, None, a.has("--dry-run"), a.has("--verbose"))
}

/// Scan these roots (all of each, or only the named direct subfolders), then make sure the
/// follow-up rewrites will happen (watcher, or a hidden helper).
fn run_scans(cfg: &Config, roots: &[Root], only: Option<&[String]>, dry_run: bool, verbose: bool) -> i32 {
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2).min(4);
    let mut code = 0;
    for r in roots {
        let opt = ScanOptions { dry_run, only, threads };
        match scan::scan_root(cfg, r, &opt) {
            Ok(rep) => {
                scan::print_report(&rep, verbose);
                if rep.items.iter().any(|i| i.action.starts_with("error")) {
                    code = 1;
                }
            }
            Err(e) => {
                crate::say!("refused/failed: {}: {e}", r.path.display());
                code = 2;
            }
        }
    }
    if !dry_run {
        crate::followup::ensure_handled();
    }
    code
}

/// `here`: opt in + scan. A folder inside an opted-in folder is already labelled at every level, so
/// it is only re-measured (its branch of that root), never added as a second, nested root.
fn cmd_here(a: &Args) -> i32 {
    if let Some(p) = a.pos.first() {
        if let (Ok(path), Ok(cfg)) = (folder_arg(p), Config::load()) {
            let inside = cfg.roots.iter().find(|r| key(&r.path) != key(&path) && is_under(&path, &r.path)).cloned();
            if let Some(r) = inside {
                let top = path
                    .strip_prefix(&r.path)
                    .ok()
                    .and_then(|rel| rel.components().next())
                    .map(|c| c.as_os_str().to_string_lossy().to_string());
                if let Some(top) = top {
                    crate::say!("{} is inside {} (opted in): re-measuring {}", path.display(), r.path.display(), r.path.join(&top).display());
                    let only = [top];
                    return run_scans(&cfg, std::slice::from_ref(&r), Some(&only), false, false);
                }
            }
        }
    }
    let c = cmd_add(a);
    if c == 0 { cmd_scan(a) } else { c }
}

fn cmd_clean(a: &Args) -> i32 {
    let all = a.has("--all");
    let path = if all {
        None
    } else {
        let Some(p) = a.pos.first() else {
            crate::say!("usage: sizelens clean <folder> | --all");
            return 3;
        };
        let t = p.trim().trim_matches('"');
        // Don't require the folder to still exist: clean must work from the record alone.
        Some(norm_path(Path::new(t)).unwrap_or_else(|_| PathBuf::from(t)))
    };
    // Opt out first, so a running watcher stops touching it.
    if !a.has("--keep-root") {
        if let Ok(mut cfg) = Config::load() {
            let targets: Vec<PathBuf> = match &path {
                None => cfg.roots.iter().map(|r| r.path.clone()).collect(),
                Some(p) => vec![p.clone()],
            };
            for t in targets {
                if let Ok(true) = cfg.remove_root(&t) {
                    crate::say!("opted out: {}", t.display());
                }
            }
        }
    }
    match scan::clean(path.as_deref()) {
        Ok((ok, failed)) => {
            crate::say!("clean: {ok} folder(s) restored, {failed} failed.");
            if failed > 0 { 1 } else { 0 }
        }
        Err(e) => {
            crate::say!("error: {e}");
            1
        }
    }
}

fn cmd_status() -> i32 {
    let cfg = match Config::load() {
        Ok(c) => c,
        Err(e) => {
            crate::say!("error: {e}");
            return 1;
        }
    };
    let sizes = store::load_sizes();
    let man = store::load_managed();
    crate::say!("SizeLens {}", env!("CARGO_PKG_VERSION"));
    crate::say!("  data folder : {}", data_dir().display());
    crate::say!("  config      : {}", config::path().display());
    crate::say!("  size index  : {}", store::sizes_path().display());
    crate::say!("  undo log    : {}  ({} folders changed)", store::managed_path().display(), man.len());
    crate::say!("  format      : {}{}", cfg.format.name(), if cfg.show_files { " + file count" } else { "" });
    crate::say!("  watcher     : {}", if watch::is_running() { "running" } else { "not running" });
    let pending = crate::followup::load().len();
    crate::say!(
        "  follow-ups  : {} pending (each changed label is written once more {} s later, for open Explorer windows)",
        pending,
        cfg.follow_up_secs
    );
    if cfg.roots.is_empty() {
        crate::say!("\nNo folders opted in. Use `sizelens add <folder>`.");
        return 0;
    }
    for r in &cfg.roots {
        let rows: Vec<_> = sizes.values().filter(|s| key(&s.root) == key(&r.path) && s.path.parent().map(|p| key(p) == key(&r.path)).unwrap_or(false)).collect();
        let deep = sizes.values().filter(|s| key(&s.root) == key(&r.path)).count() - rows.len();
        let total: u64 = rows.iter().map(|s| s.bytes).sum();
        let last = rows.iter().map(|s| s.scanned_at.as_str()).max().unwrap_or("never");
        crate::say!(
            "\n{}{}{}\n  {} subfolders (+{} deeper folders labelled), {} total, last scan {}",
            r.path.display(),
            if r.allow_onedrive { "  [allow-onedrive]" } else { "" },
            if r.allow_drive_root { "  [allow-drive-root]" } else { "" },
            rows.len(),
            deep,
            fmt::readable(total),
            last
        );
        let mut top = rows.clone();
        top.sort_by(|a, b| b.bytes.cmp(&a.bytes));
        for s in top.iter().take(10) {
            let name = s.path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            crate::say!(
                "  {:>10}  {:>9} files  {}{}",
                fmt::readable(s.bytes),
                crate::util::human_count(s.files),
                name,
                if s.unreadable > 0 { "  (partial)" } else { "" }
            );
        }
    }
    0
}

fn cmd_stop() -> i32 {
    if !watch::is_running() {
        crate::say!("No watcher is running.");
        return 0;
    }
    let _ = std::fs::create_dir_all(data_dir());
    match std::fs::write(watch::stop_flag(), b"stop") {
        Ok(()) => {
            crate::say!("Stop requested; the watcher exits within a few seconds.");
            0
        }
        Err(e) => {
            crate::say!("error: {e}");
            1
        }
    }
}

fn cmd_fmt(a: &Args) -> i32 {
    for b in &a.pos {
        match b.replace(',', "").parse::<u64>() {
            Ok(n) => crate::say!(
                "{n}\t{}\t{}\t{}",
                fmt::sortable(n),
                fmt::exact(n),
                fmt::readable(n)
            ),
            Err(_) => {
                crate::say!("not a number: {b}");
                return 3;
            }
        }
    }
    0
}
