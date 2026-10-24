//! Writing and undoing the desktop.ini InfoTip in one folder.

use crate::ini;
use crate::store::Managed;
use crate::util::{backups_dir, fnv64, key, nanos_to_time, time_to_nanos, write_atomic};
use crate::win::{self, ATTR_HIDDEN, ATTR_NORMAL, ATTR_READONLY, ATTR_SYSTEM};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::path::Path;
use std::time::SystemTime;

fn ini_path(folder: &Path) -> std::path::PathBuf {
    folder.join("desktop.ini")
}

fn read_opt(p: &Path) -> Result<Option<Vec<u8>>, String> {
    match fs::read(p) {
        Ok(b) => Ok(Some(b)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("can't read {}: {e}", p.display())),
    }
}

fn mtime(p: &Path) -> Option<SystemTime> {
    fs::metadata(p).and_then(|m| m.modified()).ok()
}

/// Set a file's or folder's modified time (folders need backup semantics to be opened).
fn set_mtime(p: &Path, t: SystemTime) {
    use std::os::windows::fs::OpenOptionsExt;
    const FILE_WRITE_ATTRIBUTES: u32 = 0x100;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    if let Ok(f) = OpenOptions::new()
        .access_mode(FILE_WRITE_ATTRIBUTES)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(p)
    {
        let _ = f.set_modified(t);
    }
}

/// Write bytes to desktop.ini even if it is Hidden/System/Read-only, then set `attrs`.
fn write_ini(p: &Path, bytes: &[u8], exists: bool, attrs: u32) -> Result<(), String> {
    let before = if exists { win::get_attrs(p).ok() } else { None };
    if exists {
        win::set_attrs(p, ATTR_NORMAL)?;
    }
    if let Err(e) = fs::write(p, bytes) {
        if let Some(a) = before {
            let _ = win::set_attrs(p, a);
        }
        return Err(format!("can't write {}: {e}", p.display()));
    }
    win::set_attrs(p, attrs)
}

/// First time SizeLens touches a folder: record its state and back up any desktop.ini.
/// The caller saves managed.tsv before any desktop.ini is written.
pub fn prepare(folder: &Path, root: &Path, man: &mut BTreeMap<String, Managed>) -> Result<(), String> {
    let k = key(folder);
    if man.contains_key(&k) {
        return Ok(());
    }
    let ini = ini_path(folder);
    let folder_attrs = win::get_attrs(folder)?;
    let existing = read_opt(&ini)?;
    let (created, backup, ini_attrs, ini_mtime) = match existing {
        Some(bytes) => {
            let name = format!("{:016x}.ini", fnv64(k.as_bytes()));
            let bp = backups_dir().join(&name);
            if !bp.exists() {
                write_atomic(&bp, &bytes).map_err(|e| format!("can't back up desktop.ini: {e}"))?;
            }
            let a = win::get_attrs(&ini)?;
            let t = mtime(&ini).map(time_to_nanos).unwrap_or(0);
            (false, Some(name), a, t)
        }
        None => (true, None, 0, 0),
    };
    man.insert(
        k,
        Managed {
            path: folder.to_path_buf(),
            root: root.to_path_buf(),
            created,
            backup,
            folder_attrs,
            added_ro: false,
            ini_attrs,
            ini_mtime,
            written: 0,
        },
    );
    Ok(())
}

/// Put `tip` into the folder's desktop.ini. Returns true if anything was written.
pub fn write_tip(folder: &Path, tip: &str, generic: bool, man: &mut BTreeMap<String, Managed>) -> Result<bool, String> {
    let k = key(folder);
    let m = man.get_mut(&k).ok_or("internal: folder not prepared")?;
    let ini = ini_path(folder);
    let existing = read_opt(&ini)?;
    let new_bytes = match &existing {
        Some(b) => {
            let (enc, text) = ini::decode(b);
            ini::encode(enc, &ini::set_infotip(&text, tip))
        }
        None => ini::new_file(tip, generic),
    };
    let folder_attrs = win::get_attrs(folder)?;
    let ini_attrs_now = if existing.is_some() { win::get_attrs(&ini)? } else { 0 };
    let want_ini_attrs = if existing.is_some() {
        ini_attrs_now | ATTR_HIDDEN | ATTR_SYSTEM
    } else {
        ATTR_HIDDEN | ATTR_SYSTEM
    };
    let folder_ok = folder_attrs & (ATTR_READONLY | ATTR_SYSTEM) != 0;
    if existing.as_deref() == Some(&new_bytes[..])
        && ini_attrs_now & (ATTR_HIDDEN | ATTR_SYSTEM) == (ATTR_HIDDEN | ATTR_SYSTEM)
        && folder_ok
    {
        m.written = fnv64(&new_bytes);
        return Ok(false);
    }
    let folder_mtime = mtime(folder);
    write_ini(&ini, &new_bytes, existing.is_some(), want_ini_attrs)?;
    m.written = fnv64(&new_bytes);
    if !folder_ok {
        win::set_attrs(folder, folder_attrs | ATTR_READONLY)?;
        m.added_ro = true;
    }
    // Creating a file bumps the folder's "Date modified"; put it back.
    if let Some(t) = folder_mtime {
        set_mtime(folder, t);
    }
    win::notify_item(folder);
    Ok(true)
}

/// Write the folder's desktop.ini again with the same bytes, so an open Explorer window that ignored
/// the last change re-reads it (see followup.rs). Only when the file is still exactly what SizeLens
/// last wrote. The folder's "Date modified" is kept. Returns true if it was written.
pub fn rewrite_same(folder: &Path, m: &Managed) -> Result<bool, String> {
    let ini = ini_path(folder);
    let Some(bytes) = read_opt(&ini)? else {
        return Ok(false);
    };
    if fnv64(&bytes) != m.written {
        return Ok(false);
    }
    let attrs = win::get_attrs(&ini)?;
    let folder_mtime = mtime(folder);
    write_ini(&ini, &bytes, true, attrs)?;
    if let Some(t) = folder_mtime {
        set_mtime(folder, t);
    }
    win::notify_item(folder);
    Ok(true)
}

/// Undo everything SizeLens did in one folder. Returns a note for the report.
pub fn clean_one(m: &Managed) -> Result<String, String> {
    let folder = &m.path;
    if !folder.is_dir() {
        return Ok("folder no longer exists".into());
    }
    let ini = ini_path(folder);
    let folder_mtime = mtime(folder);
    let current = read_opt(&ini)?;
    let mut note = String::from("restored");
    let mut keep_ro = false;
    match (&current, m.created) {
        (None, _) => note = "desktop.ini was already removed".into(),
        (Some(cur), true) => {
            if fnv64(cur) == m.written {
                win::set_attrs(&ini, ATTR_NORMAL)?;
                fs::remove_file(&ini).map_err(|e| format!("can't remove {}: {e}", ini.display()))?;
                note = "removed desktop.ini SizeLens created".into();
            } else {
                // Someone added their own settings to the file SizeLens created: keep the file,
                // take out only the InfoTip.
                let (enc, text) = ini::decode(cur);
                let out = ini::encode(enc, &ini::remove_infotip(&text, true));
                write_ini(&ini, &out, true, ATTR_HIDDEN | ATTR_SYSTEM)?;
                keep_ro = true;
                note = "desktop.ini had other changes; removed only InfoTip and kept the file".into();
            }
        }
        (Some(cur), false) => {
            let name = m.backup.as_deref().ok_or("backup name missing in managed.tsv")?;
            let bp = backups_dir().join(name);
            let orig = fs::read(&bp).map_err(|e| format!("backup {} unreadable: {e}", bp.display()))?;
            let out = if fnv64(cur) == m.written {
                orig.clone()
            } else {
                let (enc, text) = ini::decode(cur);
                let (_, otext) = ini::decode(&orig);
                note = "desktop.ini changed since; restored only the InfoTip line".into();
                ini::encode(enc, &ini::revert(&text, &otext))
            };
            write_ini(&ini, &out, true, m.ini_attrs)?;
            if m.ini_mtime != 0 && out == orig {
                set_mtime(&ini, nanos_to_time(m.ini_mtime));
            }
        }
    }
    if m.added_ro && !keep_ro {
        let a = win::get_attrs(folder)?;
        win::set_attrs(folder, a & !ATTR_READONLY)?;
    }
    if let Some(t) = folder_mtime {
        set_mtime(folder, t);
    }
    win::notify_item(folder);
    Ok(note)
}

/// Remove a folder's backup file once it is no longer needed.
pub fn drop_backup(m: &Managed) {
    if let Some(name) = &m.backup {
        let _ = fs::remove_file(backups_dir().join(name));
    }
}
