//! The handful of Win32 calls SizeLens needs, declared directly (no extra crates).

use std::ffi::c_void;
use std::os::windows::ffi::OsStrExt;
use std::path::Path;

pub type Handle = *mut c_void;
pub const INVALID_HANDLE: Handle = -1isize as Handle;

pub const ATTR_READONLY: u32 = 0x1;
pub const ATTR_HIDDEN: u32 = 0x2;
pub const ATTR_SYSTEM: u32 = 0x4;
pub const ATTR_DIRECTORY: u32 = 0x10;
pub const ATTR_NORMAL: u32 = 0x80;
pub const ATTR_REPARSE: u32 = 0x400;
const INVALID_ATTRS: u32 = u32::MAX;

#[link(name = "kernel32")]
extern "system" {
    fn SetFileAttributesW(name: *const u16, attrs: u32) -> i32;
    fn GetFileAttributesW(name: *const u16) -> u32;
    fn GetDriveTypeW(root: *const u16) -> u32;
    fn CreateMutexW(attrs: *const c_void, initial_owner: i32, name: *const u16) -> Handle;
    fn GetLastError() -> u32;
    fn CloseHandle(h: Handle) -> i32;
    fn GetCurrentProcess() -> Handle;
    fn SetPriorityClass(h: Handle, class: u32) -> i32;
    fn GetStdHandle(which: u32) -> Handle;
    fn SetHandleInformation(h: Handle, mask: u32, flags: u32) -> i32;
    fn CreateFileW(
        name: *const u16,
        access: u32,
        share: u32,
        sa: *const c_void,
        disposition: u32,
        flags: u32,
        template: Handle,
    ) -> Handle;
    fn ReadDirectoryChangesW(
        h: Handle,
        buf: *mut c_void,
        len: u32,
        subtree: i32,
        filter: u32,
        returned: *mut u32,
        overlapped: *mut c_void,
        routine: *const c_void,
    ) -> i32;
}

#[link(name = "shell32")]
extern "system" {
    fn SHChangeNotify(event: i32, flags: u32, item1: *const c_void, item2: *const c_void);
}

#[link(name = "advapi32")]
extern "system" {
    fn RegOpenKeyExW(key: isize, sub: *const u16, opts: u32, sam: u32, out: *mut isize) -> i32;
    fn RegEnumKeyExW(
        key: isize,
        idx: u32,
        name: *mut u16,
        name_len: *mut u32,
        reserved: *mut u32,
        class: *mut u16,
        class_len: *mut u32,
        ft: *mut c_void,
    ) -> i32;
    fn RegGetValueW(
        key: isize,
        sub: *const u16,
        value: *const u16,
        flags: u32,
        ty: *mut u32,
        data: *mut c_void,
        len: *mut u32,
    ) -> i32;
    fn RegCloseKey(key: isize) -> i32;
}

pub fn wide_str(s: &str) -> Vec<u16> {
    std::ffi::OsStr::new(s).encode_wide().chain(Some(0)).collect()
}

/// Wide path, with the `\\?\` prefix for long paths so the W APIs accept them.
pub fn wide_path(p: &Path) -> Vec<u16> {
    let s = p.to_string_lossy();
    let s = if s.len() > 240 && !s.starts_with(r"\\") {
        format!(r"\\?\{s}")
    } else {
        s.into_owned()
    };
    wide_str(&s)
}

pub fn get_attrs(p: &Path) -> Result<u32, String> {
    let w = wide_path(p);
    let a = unsafe { GetFileAttributesW(w.as_ptr()) };
    if a == INVALID_ATTRS {
        Err(format!("can't read attributes of {}: {}", p.display(), std::io::Error::last_os_error()))
    } else {
        Ok(a)
    }
}

pub fn set_attrs(p: &Path, attrs: u32) -> Result<(), String> {
    let w = wide_path(p);
    // SetFileAttributes ignores DIRECTORY/REPARSE bits; strip them to keep the call clean.
    let a = attrs & !(ATTR_DIRECTORY | ATTR_REPARSE);
    let a = if a == 0 { ATTR_NORMAL } else { a };
    if unsafe { SetFileAttributesW(w.as_ptr(), a) } == 0 {
        Err(format!("can't set attributes on {}: {}", p.display(), std::io::Error::last_os_error()))
    } else {
        Ok(())
    }
}

pub const DRIVE_REMOTE: u32 = 4;
pub const DRIVE_CDROM: u32 = 5;

pub fn drive_type(drive_root: &str) -> u32 {
    let w = wide_str(drive_root);
    unsafe { GetDriveTypeW(w.as_ptr()) }
}

const SHCNE_UPDATEDIR: i32 = 0x0000_1000;
const SHCNE_UPDATEITEM: i32 = 0x0000_2000;
const SHCNF_PATHW: u32 = 0x0005;
const SHCNF_FLUSH: u32 = 0x1000;

/// SIZELENS_NO_NOTIFY=1 turns the Explorer notifications off (only used to test what they do).
fn notify_off() -> bool {
    std::env::var_os("SIZELENS_NO_NOTIFY").is_some()
}

/// Tell Explorer a folder's properties changed (so the Comments column can refresh).
pub fn notify_item(p: &Path) {
    if notify_off() {
        return;
    }
    let w = wide_str(&p.to_string_lossy());
    unsafe { SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW, w.as_ptr() as _, std::ptr::null()) }
}

/// Tell Explorer a folder's contents changed (an open window showing it re-reads its items).
/// `flush` waits until Explorer has taken every pending notification.
pub fn notify_dir(p: &Path, flush: bool) {
    if notify_off() {
        return;
    }
    let w = wide_str(&p.to_string_lossy());
    let flags = if flush { SHCNF_PATHW | SHCNF_FLUSH } else { SHCNF_PATHW };
    unsafe { SHChangeNotify(SHCNE_UPDATEDIR, flags, w.as_ptr() as _, std::ptr::null()) }
}

/// Background mode: lower CPU *and* I/O priority for this process.
pub fn background_priority() {
    const PROCESS_MODE_BACKGROUND_BEGIN: u32 = 0x0010_0000;
    unsafe {
        SetPriorityClass(GetCurrentProcess(), PROCESS_MODE_BACKGROUND_BEGIN);
    }
}

/// Stop this process's stdin/stdout/stderr from being inherited by children it starts. Rust's
/// spawn inherits every inheritable handle, so a helper started from `sizelens scan | ...` would
/// otherwise keep the caller's pipe open (and the caller waiting) until the helper exits.
pub fn std_handles_not_inheritable() {
    const HANDLE_FLAG_INHERIT: u32 = 0x1;
    for which in [-10i32 as u32, -11i32 as u32, -12i32 as u32] {
        unsafe {
            let h = GetStdHandle(which);
            if !h.is_null() && h != INVALID_HANDLE {
                SetHandleInformation(h, HANDLE_FLAG_INHERIT, 0);
            }
        }
    }
}

/// A named mutex: Some(handle) if we are the only holder, None if another process has it.
pub struct NamedMutex(Handle);
unsafe impl Send for NamedMutex {}

impl NamedMutex {
    pub fn claim(name: &str) -> Option<NamedMutex> {
        const ERROR_ALREADY_EXISTS: u32 = 183;
        let w = wide_str(name);
        let h = unsafe { CreateMutexW(std::ptr::null(), 0, w.as_ptr()) };
        if h.is_null() {
            return None;
        }
        if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
            unsafe { CloseHandle(h) };
            return None;
        }
        Some(NamedMutex(h))
    }
}

impl Drop for NamedMutex {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

/// Blocking directory watcher (ReadDirectoryChangesW, recursive).
pub struct DirWatch(Handle);
unsafe impl Send for DirWatch {}

pub enum Change {
    /// A path relative to the watched folder.
    Path(String),
    /// The change buffer overflowed: anything may have changed.
    Overflow,
}

impl DirWatch {
    pub fn open(dir: &Path) -> Result<DirWatch, String> {
        const FILE_LIST_DIRECTORY: u32 = 0x1;
        const SHARE_ALL: u32 = 0x7;
        const OPEN_EXISTING: u32 = 3;
        const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
        let w = wide_path(dir);
        let h = unsafe {
            CreateFileW(
                w.as_ptr(),
                FILE_LIST_DIRECTORY,
                SHARE_ALL,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS,
                std::ptr::null_mut(),
            )
        };
        if h == INVALID_HANDLE || h.is_null() {
            return Err(format!("can't watch {}: {}", dir.display(), std::io::Error::last_os_error()));
        }
        Ok(DirWatch(h))
    }

    /// Blocks until something changes under the folder.
    pub fn next_batch(&mut self) -> Result<Vec<Change>, String> {
        const FILE_NAME: u32 = 0x1;
        const DIR_NAME: u32 = 0x2;
        const SIZE: u32 = 0x8;
        let mut buf = vec![0u32; 16 * 1024]; // 64 KB, DWORD aligned
        let mut got: u32 = 0;
        let ok = unsafe {
            ReadDirectoryChangesW(
                self.0,
                buf.as_mut_ptr() as _,
                (buf.len() * 4) as u32,
                1,
                FILE_NAME | DIR_NAME | SIZE,
                &mut got,
                std::ptr::null_mut(),
                std::ptr::null(),
            )
        };
        if ok == 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        if got == 0 {
            return Ok(vec![Change::Overflow]);
        }
        let bytes: &[u8] =
            unsafe { std::slice::from_raw_parts(buf.as_ptr() as *const u8, got as usize) };
        let mut out = Vec::new();
        let mut off = 0usize;
        loop {
            if off + 12 > bytes.len() {
                break;
            }
            let next = u32::from_le_bytes(bytes[off..off + 4].try_into().unwrap()) as usize;
            let name_len = u32::from_le_bytes(bytes[off + 8..off + 12].try_into().unwrap()) as usize;
            let start = off + 12;
            let end = (start + name_len).min(bytes.len());
            let units: Vec<u16> = bytes[start..end]
                .chunks_exact(2)
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect();
            out.push(Change::Path(String::from_utf16_lossy(&units)));
            if next == 0 {
                break;
            }
            off += next;
        }
        Ok(out)
    }
}

impl Drop for DirWatch {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

/// OneDrive folders from HKCU\Software\Microsoft\OneDrive\Accounts\*\UserFolder (read only).
pub fn onedrive_folders_from_registry() -> Vec<String> {
    const HKCU: isize = 0x8000_0001u32 as i32 as isize;
    const KEY_READ: u32 = 0x20019;
    const RRF_RT_REG_SZ: u32 = 0x2;
    let mut out = Vec::new();
    let sub = wide_str(r"Software\Microsoft\OneDrive\Accounts");
    let mut hk: isize = 0;
    if unsafe { RegOpenKeyExW(HKCU, sub.as_ptr(), 0, KEY_READ, &mut hk) } != 0 {
        return out;
    }
    let value = wide_str("UserFolder");
    for i in 0..64u32 {
        let mut name = [0u16; 256];
        let mut len = name.len() as u32;
        let r = unsafe {
            RegEnumKeyExW(
                hk,
                i,
                name.as_mut_ptr(),
                &mut len,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        if r != 0 {
            break;
        }
        let mut subname: Vec<u16> = name[..len as usize].to_vec();
        subname.push(0);
        let mut data = [0u16; 1024];
        let mut dlen = (data.len() * 2) as u32;
        let r = unsafe {
            RegGetValueW(
                hk,
                subname.as_ptr(),
                value.as_ptr(),
                RRF_RT_REG_SZ,
                std::ptr::null_mut(),
                data.as_mut_ptr() as _,
                &mut dlen,
            )
        };
        if r == 0 {
            let n = (dlen as usize / 2).saturating_sub(1);
            let s = String::from_utf16_lossy(&data[..n]);
            if !s.trim().is_empty() {
                out.push(s);
            }
        }
    }
    unsafe { RegCloseKey(hk) };
    out
}
