//! Measuring folders and running a scan of one root.
//!
//! One walk per top-level subfolder gives every folder below it its recursive total (children
//! are added into parents after the walk), so labelling every level costs no extra disk reads.

use crate::apply;
use crate::config::{Config, Root};
use crate::fmt;
use crate::safety;
use crate::store::{self, SizeRow};
use crate::util::{is_under, key, now_iso, Lock};
use crate::win;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

#[derive(Clone, Copy, Debug, Default)]
pub struct Totals {
    pub bytes: u64,
    pub files: u64,
    pub folders: u64,
    /// Folders that could not be listed (access denied etc.); the total is then partial.
    pub unreadable: u64,
    /// Symlinks and junctions seen and not followed.
    pub links: u64,
}

impl Totals {
    fn add(&mut self, o: &Totals) {
        self.bytes += o.bytes;
        self.files += o.files;
        self.folders += o.folders;
        self.unreadable += o.unreadable;
        self.links += o.links;
    }
}

/// One folder of a measured tree.
pub struct Measured {
    pub path: PathBuf,
    /// 1 = a direct subfolder of the root.
    pub depth: usize,
    /// Recursive total.
    pub totals: Totals,
    /// Why this folder gets no label (None = it may get one).
    pub skip: Option<String>,
}

/// Why a folder (and everything in it) never gets a label, judged from its name and attributes.
fn skip_reason(cfg: &Config, name: &str, attrs: u32) -> Option<String> {
    if attrs & win::ATTR_HIDDEN != 0 {
        return Some("hidden folder".into());
    }
    if cfg.skip_name(name) {
        return Some("skip_names".into());
    }
    None
}

/// Walk `top` (at `depth`) and return every folder in it with its recursive total.
/// Rules for the totals: every file's size (hidden too) = the "Size" Properties shows;
/// links/junctions are not followed; files named desktop.ini are not counted (they hold the
/// labels themselves, so counting them would change the numbers each time they are written).
/// On Windows `read_dir` returns each entry's size and attributes, so this is one directory
/// listing per folder and no per-file calls.
pub fn measure_tree(cfg: &Config, top: &Path, depth: usize, top_skip: Option<String>) -> Vec<Measured> {
    use std::os::windows::fs::MetadataExt;
    struct Node {
        path: PathBuf,
        parent: usize,
        depth: usize,
        t: Totals,
        skip: Option<String>,
    }
    let mut nodes = vec![Node { path: top.to_path_buf(), parent: usize::MAX, depth, t: Totals::default(), skip: top_skip }];
    let mut stack = vec![0usize];
    while let Some(i) = stack.pop() {
        let rd = match std::fs::read_dir(&nodes[i].path) {
            Ok(rd) => rd,
            Err(_) => {
                nodes[i].t.unreadable += 1;
                // Its size is unknown, and a desktop.ini created here would inherit the same
                // deny rule (unreadable for SizeLens later): leave it unlabelled.
                if nodes[i].skip.is_none() {
                    nodes[i].skip = Some("can't list its contents (access denied)".into());
                }
                continue;
            }
        };
        let mut own = Totals::default();
        let mut dirs: Vec<(PathBuf, String, u32)> = Vec::new();
        let mut is_repo = false;
        for entry in rd {
            let Ok(entry) = entry else {
                own.unreadable += 1;
                continue;
            };
            let Ok(ft) = entry.file_type() else { continue };
            let name = entry.file_name().to_string_lossy().to_string();
            if name.eq_ignore_ascii_case(".git") {
                is_repo = true;
            }
            if ft.is_symlink() {
                // Rust reports junctions and directory/file symlinks (name-surrogate reparse
                // points) as symlinks. Not followed, not counted, like a shortcut.
                own.links += 1;
            } else if ft.is_dir() {
                own.folders += 1;
                let attrs = entry.metadata().map(|m| m.file_attributes()).unwrap_or(0);
                dirs.push((entry.path(), name, attrs));
            } else if name.eq_ignore_ascii_case("desktop.ini") {
                continue;
            } else if let Ok(md) = entry.metadata() {
                own.files += 1;
                own.bytes += md.len();
            }
        }
        nodes[i].t = own;
        if is_repo && cfg.skip_git && nodes[i].skip.is_none() {
            nodes[i].skip = Some("git repository (git_repos = skip)".into());
        }
        let inherited = nodes[i].skip.as_ref().map(|_| "inside a skipped folder".to_string());
        let d = nodes[i].depth + 1;
        for (p, name, attrs) in dirs {
            let skip = inherited.clone().or_else(|| skip_reason(cfg, &name, attrs));
            nodes.push(Node { path: p, parent: i, depth: d, t: Totals::default(), skip });
            stack.push(nodes.len() - 1);
        }
    }
    // Children always come after their parent in `nodes`: fold totals upwards.
    for i in (1..nodes.len()).rev() {
        let t = nodes[i].t;
        let p = nodes[i].parent;
        nodes[p].t.add(&t);
    }
    nodes
        .into_iter()
        .map(|n| Measured { path: n.path, depth: n.depth, totals: n.t, skip: n.skip })
        .collect()
}

/// Total of one folder (used by tests and `status`).
pub fn measure(cfg: &Config, dir: &Path) -> Totals {
    measure_tree(cfg, dir, 1, None).first().map(|m| m.totals).unwrap_or_default()
}

pub struct Item {
    /// Path relative to the root, e.g. `alpha\sub1`.
    pub name: String,
    pub path: PathBuf,
    pub depth: usize,
    pub totals: Totals,
    pub tip: String,
    pub action: String,
}

pub struct Report {
    pub root: PathBuf,
    pub items: Vec<Item>,
    /// Direct subfolders skipped, and why.
    pub skipped: Vec<(String, String)>,
    /// Deeper folders skipped (hidden, skip_names, git repos and their contents).
    pub skipped_deep: usize,
    /// Labels removed because the folder is gone or no longer qualifies.
    pub removed: Vec<String>,
}

/// Direct subfolders of the root, plus the ones that are skipped outright and why.
fn subfolders(cfg: &Config, root: &Root) -> Result<(Vec<(PathBuf, Option<String>)>, Vec<(String, String)>), String> {
    use std::os::windows::fs::MetadataExt;
    let rd = std::fs::read_dir(&root.path).map_err(|e| format!("can't list {}: {e}", root.path.display()))?;
    let mut dirs = Vec::new();
    let mut skipped = Vec::new();
    for e in rd.flatten() {
        let Ok(ft) = e.file_type() else { continue };
        let name = e.file_name().to_string_lossy().to_string();
        if ft.is_symlink() {
            if std::fs::metadata(e.path()).map(|m| m.is_dir()).unwrap_or(false) {
                skipped.push((name, "link/junction (not followed)".into()));
            }
            continue;
        }
        if !ft.is_dir() {
            continue;
        }
        let attrs = e.metadata().map(|m| m.file_attributes()).unwrap_or(0);
        if attrs & (win::ATTR_HIDDEN | win::ATTR_SYSTEM) == (win::ATTR_HIDDEN | win::ATTR_SYSTEM) {
            skipped.push((name, "protected system folder (hidden + system)".into()));
            continue;
        }
        let p = e.path();
        if let Some(why) = safety::protected_reason(&p, root.allow_onedrive) {
            skipped.push((name, why));
            continue;
        }
        // Hidden / skip_names folders are still measured? No: nothing in them is labelled and the
        // root itself has no label, so there is nothing to measure them for.
        if let Some(why) = skip_reason(cfg, &name, attrs) {
            skipped.push((name, why));
            continue;
        }
        dirs.push((p, None));
    }
    dirs.sort_by_key(|(p, _)| key(p));
    Ok((dirs, skipped))
}

pub struct ScanOptions<'a> {
    pub dry_run: bool,
    /// Only these direct-subfolder names (watch mode). None = all.
    pub only: Option<&'a [String]>,
    pub threads: usize,
}

fn rel_name(root: &Path, p: &Path) -> String {
    p.strip_prefix(root).map(|r| r.to_string_lossy().to_string()).unwrap_or_else(|_| p.display().to_string())
}

pub fn scan_root(cfg: &Config, root: &Root, opt: &ScanOptions) -> Result<Report, String> {
    safety::check_root(&root.path, root.allow_onedrive, root.allow_drive_root)?;
    let (mut dirs, skipped) = subfolders(cfg, root)?;
    if let Some(only) = opt.only {
        dirs.retain(|(d, _)| {
            let n = d.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
            only.iter().any(|o| o.to_lowercase() == n)
        });
    }

    // Measure each direct subfolder's whole tree (in parallel for interactive scans).
    let next = AtomicUsize::new(0);
    let threads = opt.threads.clamp(1, 8).min(dirs.len().max(1));
    let mut trees: Vec<(usize, Vec<Measured>)> = std::thread::scope(|s| {
        let handles: Vec<_> = (0..threads)
            .map(|_| {
                s.spawn(|| {
                    let mut out = Vec::new();
                    loop {
                        let i = next.fetch_add(1, Ordering::Relaxed);
                        if i >= dirs.len() {
                            break;
                        }
                        out.push((i, measure_tree(cfg, &dirs[i].0, 1, dirs[i].1.clone())));
                    }
                    out
                })
            })
            .collect();
        handles.into_iter().flat_map(|h| h.join().unwrap_or_default()).collect()
    });
    trees.sort_by_key(|(i, _)| *i);

    let mut items = Vec::new();
    let mut skipped_deep = 0usize;
    for (_, tree) in trees {
        for m in tree {
            if m.skip.is_some() {
                skipped_deep += 1;
                continue;
            }
            if cfg.depth.map(|d| m.depth > d).unwrap_or(false) {
                continue;
            }
            items.push(Item {
                name: rel_name(&root.path, &m.path),
                tip: fmt::tip(cfg.format, m.totals.bytes, m.totals.files, cfg.show_files, m.totals.unreadable > 0),
                path: m.path,
                depth: m.depth,
                totals: m.totals,
                action: String::new(),
            });
        }
    }

    let mut removed = Vec::new();
    if opt.dry_run {
        for it in &mut items {
            it.action = "dry run".into();
        }
        return Ok(Report { root: root.path.clone(), items, skipped, skipped_deep, removed });
    }

    let _lock = Lock::acquire()?;
    // Re-check under the lock: a `clean` may have opted this folder out while we measured.
    if Config::load()?.find_root(&root.path).is_none() {
        return Err(format!("{} is no longer in config.txt; nothing written", root.path.display()));
    }
    let mut sizes = store::load_sizes();
    let mut man = store::load_managed();

    // Phase 1: record state + back up existing desktop.ini files, and save that first.
    for it in &mut items {
        if let Err(e) = apply::prepare(&it.path, &root.path, &mut man) {
            it.action = format!("error: {e}");
        }
    }
    store::save_managed(&man)?;

    // Phase 2: write the InfoTips (only where the text changed).
    let now = now_iso();
    let mut changed_parents: BTreeSet<String> = BTreeSet::new();
    let mut parent_paths: Vec<PathBuf> = Vec::new();
    for it in &mut items {
        if it.action.starts_with("error") {
            continue;
        }
        it.action = match apply::write_tip(&it.path, &it.tip, cfg.folder_type_generic, &mut man) {
            Ok(true) => {
                if let Some(p) = it.path.parent() {
                    if changed_parents.insert(key(p)) {
                        parent_paths.push(p.to_path_buf());
                    }
                }
                "updated".into()
            }
            Ok(false) => "unchanged".into(),
            Err(e) => format!("error: {e}"),
        };
    }

    // Which part of the tree this scan covered.
    let scope: Vec<PathBuf> = match opt.only {
        Some(names) => dirs.iter().map(|(p, _)| p.clone()).chain(names.iter().map(|n| root.path.join(n))).collect(),
        None => vec![root.path.clone()],
    };
    let in_scope = |p: &Path| -> bool { key(p) != key(&root.path) && scope.iter().any(|s| is_under(p, s)) };
    let labelled: BTreeSet<String> = items.iter().filter(|i| !i.action.starts_with("error")).map(|i| key(&i.path)).collect();

    // Labels that should no longer be there: folder deleted, or now skipped / beyond `depth`.
    let stale: Vec<String> = man
        .iter()
        .filter(|(k, m)| key(&m.root) == key(&root.path) && in_scope(&m.path) && !labelled.contains(*k))
        .map(|(k, _)| k.clone())
        .collect();
    for k in stale {
        let m = man[&k].clone();
        if !m.path.is_dir() {
            apply::drop_backup(&m);
            man.remove(&k);
            removed.push(format!("{} (folder no longer exists)", m.path.display()));
            continue;
        }
        match apply::clean_one(&m) {
            Ok(_) => {
                apply::drop_backup(&m);
                man.remove(&k);
                removed.push(format!("{} (no longer labelled: skipped or deeper than `depth`)", m.path.display()));
                if let Some(p) = m.path.parent() {
                    if changed_parents.insert(key(p)) {
                        parent_paths.push(p.to_path_buf());
                    }
                }
            }
            Err(e) => removed.push(format!("{}: could not remove old label: {e}", m.path.display())),
        }
    }

    // Size index: replace this scope's rows with the new ones.
    sizes.retain(|_, r| !(key(&r.root) == key(&root.path) && in_scope(&r.path)));
    for it in items.iter().filter(|i| !i.action.starts_with("error")) {
        sizes.insert(
            key(&it.path),
            SizeRow {
                path: it.path.clone(),
                bytes: it.totals.bytes,
                files: it.totals.files,
                folders: it.totals.folders,
                unreadable: it.totals.unreadable,
                links_skipped: it.totals.links,
                scanned_at: now.clone(),
                root: root.path.clone(),
            },
        );
    }

    store::save_managed(&man)?;
    store::save_sizes(&sizes)?;
    // One more write of each changed label a minute later, for windows that are already open.
    let changed: Vec<PathBuf> = items.iter().filter(|i| i.action == "updated").map(|i| i.path.clone()).collect();
    if let Err(e) = crate::followup::schedule_locked(&changed, cfg.follow_up_secs) {
        crate::say!("{e}");
    }
    // Tell Explorer: each changed folder already got UPDATEITEM; also refresh every folder whose
    // listing shows a changed label, so an open window updates without F5.
    for p in &parent_paths {
        win::notify_dir(p, false);
    }
    win::notify_dir(&root.path, true);
    Ok(Report { root: root.path.clone(), items, skipped, skipped_deep, removed })
}

pub fn print_report(r: &Report, verbose: bool) {
    let total: u64 = r.items.iter().filter(|i| i.depth == 1).map(|i| i.totals.bytes).sum();
    let changed = r.items.iter().filter(|i| i.action == "updated").count();
    let errors = r.items.iter().filter(|i| i.action.starts_with("error")).count();
    let top = r.items.iter().filter(|i| i.depth == 1).count();
    crate::say!(
        "{}  ({} folders labelled, {} direct; {} total; {} updated, {} errors)",
        r.root.display(),
        r.items.len(),
        top,
        fmt::readable(total),
        changed,
        errors
    );
    let mut shown: Vec<&Item> = r
        .items
        .iter()
        .filter(|i| i.depth == 1 || verbose || i.action.starts_with("error"))
        .collect();
    shown.sort_by(|a, b| b.totals.bytes.cmp(&a.totals.bytes));
    for it in &shown {
        let mut extra = String::new();
        if it.totals.unreadable > 0 {
            extra.push_str(&format!("  [{} unreadable folder(s): partial]", it.totals.unreadable));
        }
        if it.totals.links > 0 {
            extra.push_str(&format!("  [{} link(s) not followed]", it.totals.links));
        }
        crate::say!(
            "  {:>10}  {:>9} files  {:<34}  {}  ({}){}",
            fmt::readable(it.totals.bytes),
            crate::util::human_count(it.totals.files),
            it.name,
            it.tip,
            it.action,
            extra
        );
    }
    let deeper = r.items.iter().filter(|i| i.depth > 1).count();
    if deeper > 0 && !verbose {
        let up = r.items.iter().filter(|i| i.depth > 1 && i.action == "updated").count();
        crate::say!("  + {deeper} deeper folders labelled ({up} updated). --verbose lists them.");
    }
    for (n, why) in &r.skipped {
        crate::say!("  skipped {n}: {why}");
    }
    if r.skipped_deep > 0 {
        crate::say!("  {} deeper folder(s) left unlabelled (hidden, skip_names, git repos and what's inside them)", r.skipped_deep);
    }
    for p in &r.removed {
        crate::say!("  removed label: {p}");
    }
}

/// Undo SizeLens in every folder under `root` (or every folder if root is None).
pub fn clean(root: Option<&Path>) -> Result<(usize, usize), String> {
    let _lock = Lock::acquire()?;
    let mut man = store::load_managed();
    let mut sizes = store::load_sizes();
    let targets: Vec<String> = man
        .iter()
        .filter(|(_, m)| root.map(|r| key(&m.root) == key(r) || is_under(&m.path, r)).unwrap_or(true))
        .map(|(k, _)| k.clone())
        .collect();
    let mut ok = 0;
    let mut failed = 0;
    let mut parents: BTreeSet<String> = BTreeSet::new();
    let mut parent_paths = Vec::new();
    for k in targets {
        let m = man[&k].clone();
        match apply::clean_one(&m) {
            Ok(note) => {
                crate::say!("  {}: {}", m.path.display(), note);
                apply::drop_backup(&m);
                man.remove(&k);
                ok += 1;
                if let Some(p) = m.path.parent() {
                    if parents.insert(key(p)) {
                        parent_paths.push(p.to_path_buf());
                    }
                }
            }
            Err(e) => {
                crate::say!("  {}: FAILED: {} (left in managed.tsv; run clean again)", m.path.display(), e);
                failed += 1;
            }
        }
        if (ok + failed) % 100 == 0 {
            store::save_managed(&man)?;
        }
    }
    store::save_managed(&man)?;
    sizes.retain(|_, r| !root.map(|rt| key(&r.root) == key(rt) || is_under(&r.path, rt)).unwrap_or(true));
    store::save_sizes(&sizes)?;
    for p in &parent_paths {
        if p.is_dir() {
            win::notify_dir(p, false);
        }
    }
    if let Some(r) = root {
        if r.is_dir() {
            win::notify_dir(r, true);
        }
    }
    Ok((ok, failed))
}
