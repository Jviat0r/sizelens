//! Which folders SizeLens refuses to touch.

use crate::util::{data_dir, is_under, key};
use crate::win;
use std::path::{Path, PathBuf};

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from)
}

pub fn onedrive_folders() -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = ["OneDrive", "OneDriveConsumer", "OneDriveCommercial"]
        .iter()
        .filter_map(|n| env_path(n))
        .collect();
    v.extend(win::onedrive_folders_from_registry().into_iter().map(PathBuf::from));
    v.sort_by_key(|p| key(p));
    v.dedup_by_key(|p| key(p));
    v
}

/// Why a folder must not get a desktop.ini (system, program, profile or app-data folders,
/// OneDrive unless allowed). Applies to roots and to every subfolder SizeLens would write into.
pub fn protected_reason(p: &Path, allow_onedrive: bool) -> Option<String> {
    let sys_drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into());
    let mut system: Vec<PathBuf> = ["SystemRoot", "windir", "ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "ProgramData"]
        .iter()
        .filter_map(|n| env_path(n))
        .collect();
    for d in ["$Recycle.Bin", "System Volume Information", "Recovery", "Boot", "PerfLogs", "Config.Msi"] {
        system.push(PathBuf::from(format!("{sys_drive}\\{d}")));
    }
    for s in &system {
        if is_under(p, s) {
            return Some(format!("{} is a Windows/program folder", s.display()));
        }
    }
    let name = p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
    if name == "$recycle.bin" || name == "system volume information" {
        return Some("Windows system folder".into());
    }
    if let Some(profile) = env_path("USERPROFILE") {
        if key(p) == key(&profile) {
            return Some("this is your user profile folder itself (pick a folder inside it, like Downloads)".into());
        }
        if is_under(p, &profile.join("AppData")) {
            return Some("app data folders belong to programs".into());
        }
        if let Some(users) = profile.parent() {
            if key(p) == key(users) {
                return Some("this is the folder that holds every user profile".into());
            }
            if p.parent().map(|pp| key(pp) == key(users)).unwrap_or(false) {
                return Some("this is a user profile folder".into());
            }
        }
    }
    if !allow_onedrive {
        for od in onedrive_folders() {
            if is_under(p, &od) {
                return Some(format!(
                    "it is inside OneDrive ({}); desktop.ini files would sync to every device. Use --allow-onedrive if you really want this",
                    od.display()
                ));
            }
        }
    }
    if is_under(p, &data_dir()) {
        return Some("that is SizeLens's own data folder".into());
    }
    None
}

/// Checks for a folder being opted in as a root.
pub fn check_root(p: &Path, allow_onedrive: bool, allow_drive_root: bool) -> Result<(), String> {
    let s = p.to_string_lossy().to_string();
    if s.starts_with(r"\\") {
        return Err("network (UNC) folders are not supported".into());
    }
    if !p.is_dir() {
        return Err("folder not found".into());
    }
    let bytes = s.as_bytes();
    if bytes.len() >= 2 && bytes[1] == b':' {
        let drive = format!("{}:\\", &s[..1]);
        match win::drive_type(&drive) {
            win::DRIVE_REMOTE => return Err("this is a network drive".into()),
            win::DRIVE_CDROM => return Err("this is a CD/DVD drive".into()),
            _ => {}
        }
        if s.len() <= 3 && !allow_drive_root {
            return Err(
                "this is a whole drive; that would put a desktop.ini in every top-level folder. Use --allow-drive-root if you really want this"
                    .into(),
            );
        }
    }
    let a = win::get_attrs(p)?;
    if a & win::ATTR_REPARSE != 0 {
        return Err("this folder is a link (junction or symlink); add the real folder instead".into());
    }
    if let Some(why) = protected_reason(p, allow_onedrive) {
        return Err(why);
    }
    Ok(())
}
