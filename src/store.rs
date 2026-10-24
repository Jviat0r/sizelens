//! The two text files SizeLens keeps:
//! - sizes.tsv:   the size index (one line per measured folder), the "simple text file".
//! - managed.tsv: what SizeLens changed in each folder, so `clean` can undo it exactly.

use crate::util::{data_dir, key, write_atomic};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Default)]
pub struct SizeRow {
    pub path: PathBuf,
    pub bytes: u64,
    pub files: u64,
    pub folders: u64,
    pub unreadable: u64,
    pub links_skipped: u64,
    pub scanned_at: String,
    pub root: PathBuf,
}

#[derive(Clone, Debug)]
pub struct Managed {
    pub path: PathBuf,
    pub root: PathBuf,
    /// SizeLens created desktop.ini (there was none before).
    pub created: bool,
    /// Backup file name (in backups\) of the desktop.ini that was there before.
    pub backup: Option<String>,
    /// Folder attributes before SizeLens touched it.
    pub folder_attrs: u32,
    /// SizeLens added the Read-only attribute to the folder.
    pub added_ro: bool,
    /// Attributes and modified time of the pre-existing desktop.ini.
    pub ini_attrs: u32,
    pub ini_mtime: u128,
    /// FNV-1a hash of the desktop.ini bytes SizeLens last wrote.
    pub written: u64,
}

const SIZES_HEADER: &str = "# SizeLens size index. bytes = sum of file sizes (the \"Size\" in Properties, not \"Size on disk\"), not counting the folder's own desktop.ini. Links/junctions are not followed.\r\n# path\tbytes\tfiles\tfolders\tunreadable_folders\tlinks_skipped\tscanned_at_utc\troot\r\n";
const MANAGED_HEADER: &str = "# SizeLens undo log. Do not edit; `sizelens clean` reads it.\r\n# path\troot\tcreated\tbackup\tfolder_attrs\tadded_readonly\tini_attrs\tini_mtime_ns\twritten_hash\r\n";

pub fn sizes_path() -> PathBuf {
    data_dir().join("sizes.tsv")
}
pub fn managed_path() -> PathBuf {
    data_dir().join("managed.tsv")
}

fn data_lines(p: &Path) -> Vec<Vec<String>> {
    let Ok(text) = std::fs::read_to_string(p) else {
        return Vec::new();
    };
    text.lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
        .map(|l| l.split('\t').map(|s| s.to_string()).collect())
        .collect()
}

pub fn load_sizes() -> BTreeMap<String, SizeRow> {
    let mut m = BTreeMap::new();
    for f in data_lines(&sizes_path()) {
        if f.len() < 8 {
            continue;
        }
        let row = SizeRow {
            path: PathBuf::from(&f[0]),
            bytes: f[1].parse().unwrap_or(0),
            files: f[2].parse().unwrap_or(0),
            folders: f[3].parse().unwrap_or(0),
            unreadable: f[4].parse().unwrap_or(0),
            links_skipped: f[5].parse().unwrap_or(0),
            scanned_at: f[6].clone(),
            root: PathBuf::from(&f[7]),
        };
        m.insert(key(&row.path), row);
    }
    m
}

pub fn save_sizes(m: &BTreeMap<String, SizeRow>) -> Result<(), String> {
    let mut s = String::from(SIZES_HEADER);
    for r in m.values() {
        s.push_str(&format!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\r\n",
            r.path.display(),
            r.bytes,
            r.files,
            r.folders,
            r.unreadable,
            r.links_skipped,
            r.scanned_at,
            r.root.display()
        ));
    }
    write_atomic(&sizes_path(), s.as_bytes()).map_err(|e| format!("can't save sizes.tsv: {e}"))
}

pub fn load_managed() -> BTreeMap<String, Managed> {
    let mut m = BTreeMap::new();
    for f in data_lines(&managed_path()) {
        if f.len() < 9 {
            continue;
        }
        let row = Managed {
            path: PathBuf::from(&f[0]),
            root: PathBuf::from(&f[1]),
            created: f[2] == "1",
            backup: if f[3] == "-" { None } else { Some(f[3].clone()) },
            folder_attrs: f[4].parse().unwrap_or(0),
            added_ro: f[5] == "1",
            ini_attrs: f[6].parse().unwrap_or(0),
            ini_mtime: f[7].parse().unwrap_or(0),
            written: u64::from_str_radix(&f[8], 16).unwrap_or(0),
        };
        m.insert(key(&row.path), row);
    }
    m
}

pub fn save_managed(m: &BTreeMap<String, Managed>) -> Result<(), String> {
    let mut s = String::from(MANAGED_HEADER);
    for r in m.values() {
        s.push_str(&format!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{:016x}\r\n",
            r.path.display(),
            r.root.display(),
            r.created as u8,
            r.backup.as_deref().unwrap_or("-"),
            r.folder_attrs,
            r.added_ro as u8,
            r.ini_attrs,
            r.ini_mtime,
            r.written
        ));
    }
    write_atomic(&managed_path(), s.as_bytes()).map_err(|e| format!("can't save managed.tsv: {e}"))
}
