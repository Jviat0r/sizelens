use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Where config.txt, sizes.tsv, managed.tsv and backups live.
/// `SIZELENS_HOME` overrides it (the tests use this so they never touch %LOCALAPPDATA%).
pub fn data_dir() -> PathBuf {
    if let Some(h) = std::env::var_os("SIZELENS_HOME") {
        return PathBuf::from(h);
    }
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("SizeLens")
}

/// Empty for the normal data folder, `.<hash>` when SIZELENS_HOME points somewhere else. Added to the
/// names of the watcher's and helper's mutexes, so each data folder has its own.
pub fn instance_suffix() -> String {
    match std::env::var_os("SIZELENS_HOME") {
        Some(_) => format!(".{:08x}", fnv64(key(&data_dir()).as_bytes()) as u32),
        None => String::new(),
    }
}

pub fn backups_dir() -> PathBuf {
    data_dir().join("backups")
}

pub fn strip_verbatim(s: &str) -> String {
    if let Some(r) = s.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{r}")
    } else if let Some(r) = s.strip_prefix(r"\\?\") {
        r.to_string()
    } else {
        s.to_string()
    }
}

/// Absolute, canonical (junctions resolved), no `\\?\` prefix, no trailing backslash
/// (except a drive root like `D:\`).
pub fn norm_path(p: &Path) -> std::io::Result<PathBuf> {
    let abs = std::path::absolute(p)?;
    let c = fs::canonicalize(&abs).unwrap_or(abs);
    let mut s = strip_verbatim(&c.to_string_lossy()).replace('/', "\\");
    while s.len() > 3 && s.ends_with('\\') {
        s.pop();
    }
    if s.len() == 2 && s.ends_with(':') {
        s.push('\\');
    }
    Ok(PathBuf::from(s))
}

/// Case-insensitive comparison key for a path.
pub fn key(p: &Path) -> String {
    let mut s = p.to_string_lossy().replace('/', "\\").to_lowercase();
    while s.len() > 3 && s.ends_with('\\') {
        s.pop();
    }
    s
}

/// True when `p` is `base` or inside it.
pub fn is_under(p: &Path, base: &Path) -> bool {
    let a = key(p);
    let b = key(base);
    let b = b.trim_end_matches('\\');
    a == b || a.starts_with(&format!("{b}\\"))
}

pub fn fnv64(b: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for x in b {
        h ^= *x as u64;
        h = h.wrapping_mul(0x0100_0000_01b3);
    }
    h
}

pub fn now_iso() -> String {
    let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    iso(d.as_secs())
}

pub fn iso(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    let (y, m, d) = civil(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

fn civil(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

pub fn time_to_nanos(t: SystemTime) -> u128 {
    t.duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
}

pub fn nanos_to_time(n: u128) -> SystemTime {
    UNIX_EPOCH + Duration::from_nanos(n as u64)
}

/// Write via a temp file + rename, so a crash never leaves a half-written state file.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, bytes)?;
    fs::rename(&tmp, path)
}

/// Process-wide lock so the watcher and a manual scan never edit the state files at once.
pub struct Lock(#[allow(dead_code)] File);

impl Lock {
    pub fn acquire() -> Result<Lock, String> {
        use std::os::windows::fs::OpenOptionsExt;
        let dir = data_dir();
        fs::create_dir_all(&dir).map_err(|e| format!("can't create {}: {e}", dir.display()))?;
        let p = dir.join("lock");
        let start = Instant::now();
        loop {
            match OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .share_mode(0)
                .open(&p)
            {
                Ok(f) => return Ok(Lock(f)),
                Err(e) => {
                    if start.elapsed() > Duration::from_secs(300) {
                        return Err(format!("another SizeLens process is still busy ({e})"));
                    }
                    std::thread::sleep(Duration::from_millis(250));
                }
            }
        }
    }
}

pub fn human_count(n: u64) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}
