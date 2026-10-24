//! config.txt: plain text, `key = value` lines, one `root = <folder>` line per opted-in folder.

use crate::fmt::Format;
use crate::util::{data_dir, key, write_atomic};
use std::path::{Path, PathBuf};

pub const TEMPLATE: &str = "# SizeLens settings. One \"key = value\" per line; lines starting with # are ignored.
# Edit this file, or use `sizelens add <folder>` / `sizelens clean <folder>`.

# How sizes are written into Explorer's Comments column:
#   sortable  [3] 0012.40 GB   (default; sorts correctly; the digit is the size class 0=B 1=KB 2=MB 3=GB 4=TB)
#   bytes     000,013,321,456,789 bytes   (exact, sorts correctly up to 999 TB, long)
#   readable  12.4 GB          (reads best, but sorting the column will be wrong)
format = sortable

# Add the file count after the size, e.g. \"[3] 0012.40 GB - 1,234 files\".
show_files = false

# How deep to label folders under each opted-in folder: all, or a number (1 = only its direct subfolders).
depth = all

# Folders that never get a label (and nothing inside them does); their sizes still count toward their parents.
# Comma separated names; .* means every folder whose name starts with a dot (.git, .venv, ...).
# Hidden folders are always skipped too.
skip_names = .*, node_modules, __pycache__, venv, bower_components

# git working trees: skip (default) leaves every git repo folder and everything in it alone, because a
# desktop.ini would show up as an untracked file in `git status`. Use allow if desktop.ini is in your
# global gitignore.
git_repos = skip

# generic: each desktop.ini SizeLens creates also says FolderType=Generic (\"General items\"), so one
# \"Apply to Folders\" in Explorer covers every labelled folder. keep (default): leave folder types alone.
folder_type = keep

# Watch mode: re-measure a folder this many seconds after the last change inside it.
debounce_seconds = 10

# Watch mode: also re-measure everything this often, in case a change was missed.
full_rescan_minutes = 360

# An open Explorer window ignores a desktop.ini change made within about a minute of its last read, so
# SizeLens writes each changed label once more this many seconds later. 0 = off (then only newly opened
# windows show new sizes right away).
follow_up_seconds = 65

# Folders whose subfolders get sizes. Only these are ever touched.
# Optional flags after a |  :  allow-onedrive, allow-drive-root
# Example:   root = D:\\Projects
";

pub const DEFAULT_SKIP: &str = ".*, node_modules, __pycache__, venv, bower_components";

#[derive(Clone, Debug)]
pub struct Root {
    pub path: PathBuf,
    pub allow_onedrive: bool,
    pub allow_drive_root: bool,
}

#[derive(Clone, Debug)]
pub struct Config {
    pub format: Format,
    pub show_files: bool,
    pub debounce_secs: u64,
    pub full_rescan_minutes: u64,
    /// Seconds until the follow-up rewrite of a changed label (0 = off). See followup.rs.
    pub follow_up_secs: u64,
    /// None = every level.
    pub depth: Option<usize>,
    pub skip_names: Vec<String>,
    pub skip_git: bool,
    pub folder_type_generic: bool,
    pub roots: Vec<Root>,
    lines: Vec<String>,
}

pub fn path() -> PathBuf {
    data_dir().join("config.txt")
}

fn parse_list(v: &str) -> Vec<String> {
    v.split(',').map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty()).collect()
}

impl Config {
    pub fn load() -> Result<Config, String> {
        let p = path();
        if !p.exists() {
            write_atomic(&p, TEMPLATE.replace('\n', "\r\n").as_bytes())
                .map_err(|e| format!("can't create {}: {e}", p.display()))?;
        }
        let text =
            std::fs::read_to_string(&p).map_err(|e| format!("can't read {}: {e}", p.display()))?;
        Config::parse(&text)
    }

    pub fn parse(text: &str) -> Result<Config, String> {
        let mut c = Config {
            format: Format::Sortable,
            show_files: false,
            debounce_secs: 10,
            full_rescan_minutes: 360,
            follow_up_secs: 65,
            depth: None,
            skip_names: parse_list(DEFAULT_SKIP),
            skip_git: true,
            folder_type_generic: false,
            roots: Vec::new(),
            lines: text.lines().map(|s| s.to_string()).collect(),
        };
        for (n, raw) in text.lines().enumerate() {
            let line = raw.trim().trim_start_matches('\u{feff}');
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((k, v)) = line.split_once('=') else {
                return Err(format!("config.txt line {}: expected key = value", n + 1));
            };
            let (k, v) = (k.trim().to_ascii_lowercase(), v.trim());
            let bad = |what: &str| format!("config.txt line {}: {what}", n + 1);
            match k.as_str() {
                "format" => c.format = Format::parse(v).ok_or(bad(&format!("unknown format '{v}'")))?,
                "show_files" => c.show_files = matches!(v.to_ascii_lowercase().as_str(), "true" | "yes" | "1"),
                "debounce_seconds" => c.debounce_secs = v.parse().unwrap_or(10).max(1),
                "full_rescan_minutes" => c.full_rescan_minutes = v.parse().unwrap_or(360).max(5),
                "follow_up_seconds" => c.follow_up_secs = v.parse().map_err(|_| bad("follow_up_seconds must be a number"))?,
                "depth" => {
                    c.depth = if v.eq_ignore_ascii_case("all") {
                        None
                    } else {
                        Some(v.parse::<usize>().map_err(|_| bad("depth must be all or a number"))?.max(1))
                    }
                }
                "skip_names" => c.skip_names = parse_list(v),
                "git_repos" => match v.to_ascii_lowercase().as_str() {
                    "skip" => c.skip_git = true,
                    "allow" => c.skip_git = false,
                    _ => return Err(bad("git_repos must be skip or allow")),
                },
                "folder_type" => match v.to_ascii_lowercase().as_str() {
                    "keep" => c.folder_type_generic = false,
                    "generic" => c.folder_type_generic = true,
                    _ => return Err(bad("folder_type must be keep or generic")),
                },
                "root" => c.roots.push(parse_root(v)),
                _ => return Err(bad(&format!("unknown setting '{k}'"))),
            }
        }
        Ok(c)
    }

    /// Should a folder with this name never get a label?
    pub fn skip_name(&self, name: &str) -> bool {
        let n = name.to_lowercase();
        self.skip_names.iter().any(|s| {
            if s == ".*" {
                n.starts_with('.')
            } else if let Some(prefix) = s.strip_suffix('*') {
                n.starts_with(prefix)
            } else {
                *s == n
            }
        })
    }

    pub fn find_root(&self, p: &Path) -> Option<&Root> {
        let k = key(p);
        self.roots.iter().find(|r| key(&r.path) == k)
    }

    pub fn add_root(&mut self, root: Root) -> Result<(), String> {
        if self.find_root(&root.path).is_some() {
            return Ok(());
        }
        let mut flags = Vec::new();
        if root.allow_onedrive {
            flags.push("allow-onedrive");
        }
        if root.allow_drive_root {
            flags.push("allow-drive-root");
        }
        let mut line = format!("root = {}", root.path.display());
        if !flags.is_empty() {
            line.push_str(&format!(" | {}", flags.join(", ")));
        }
        self.lines.push(line);
        self.roots.push(root);
        self.save()
    }

    pub fn remove_root(&mut self, p: &Path) -> Result<bool, String> {
        let k = key(p);
        let before = self.roots.len();
        self.roots.retain(|r| key(&r.path) != k);
        if self.roots.len() == before {
            return Ok(false);
        }
        self.lines.retain(|l| {
            let t = l.trim();
            match t.split_once('=') {
                Some((kk, v)) if kk.trim().eq_ignore_ascii_case("root") => key(&parse_root(v.trim()).path) != k,
                _ => true,
            }
        });
        self.save()?;
        Ok(true)
    }

    fn save(&self) -> Result<(), String> {
        let mut text = self.lines.join("\r\n");
        text.push_str("\r\n");
        write_atomic(&path(), text.as_bytes()).map_err(|e| format!("can't save config.txt: {e}"))
    }
}

fn parse_root(v: &str) -> Root {
    let (p, flags) = match v.split_once('|') {
        Some((p, f)) => (p.trim(), f.to_ascii_lowercase()),
        None => (v.trim(), String::new()),
    };
    Root {
        path: PathBuf::from(p.trim_matches('"')),
        allow_onedrive: flags.contains("allow-onedrive"),
        allow_drive_root: flags.contains("allow-drive-root"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn follow_up_seconds_default_and_override() {
        assert_eq!(Config::parse("").unwrap().follow_up_secs, 65);
        assert_eq!(Config::parse(&TEMPLATE.replace('\n', "\r\n")).unwrap().follow_up_secs, 65);
        assert_eq!(Config::parse("follow_up_seconds = 0").unwrap().follow_up_secs, 0);
        assert_eq!(Config::parse("follow_up_seconds = 90\r\n").unwrap().follow_up_secs, 90);
        assert!(Config::parse("follow_up_seconds = soon").is_err());
    }
}