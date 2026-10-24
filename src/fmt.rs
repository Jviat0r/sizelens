//! How a size is written into the Comments column.
//!
//! Explorer sorts the Comments column as text, so the default `sortable` format starts with
//! a size class digit and a zero-padded number, which sorts the same as the byte count under
//! plain ordinal compare, case-insensitive compare and "numbers in names" (natural) compare.

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Format {
    /// `[3] 0012.40 GB`: class digit (0=B 1=KB 2=MB 3=GB 4=TB) + fixed-width number. Sorts right.
    Sortable,
    /// `000,013,321,456,789 bytes`: exact, sorts right, long.
    Bytes,
    /// `12.4 GB`: what Properties shows. Reads best, but does NOT sort right as text.
    Readable,
}

impl Format {
    pub fn parse(s: &str) -> Option<Format> {
        match s.trim().to_ascii_lowercase().as_str() {
            "sortable" => Some(Format::Sortable),
            "bytes" => Some(Format::Bytes),
            "readable" => Some(Format::Readable),
            _ => None,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Format::Sortable => "sortable",
            Format::Bytes => "bytes",
            Format::Readable => "readable",
        }
    }
}

const UNITS: [&str; 7] = ["B", "KB", "MB", "GB", "TB", "PB", "EB"];

fn rank(bytes: u64) -> usize {
    let mut r = 0;
    let mut v = bytes;
    while v >= 1024 && r < UNITS.len() - 1 {
        v /= 1024;
        r += 1;
    }
    r
}

pub fn sortable(bytes: u64) -> String {
    let r = rank(bytes);
    if r == 0 {
        format!("[0] {bytes:04} B")
    } else {
        let v = bytes as f64 / 1024f64.powi(r as i32);
        // v is in [1, 1024); rounding can give 1024.00, still 7 chars wide and still rank r,
        // so ordering stays monotonic.
        format!("[{r}] {v:07.2} {}", UNITS[r])
    }
}

/// Fixed 15 digits: sorts correctly up to 999 TB per folder.
pub fn exact(bytes: u64) -> String {
    let digits = format!("{bytes:015}");
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    format!("{out} bytes")
}

/// Explorer-style: 3 significant digits, 1024-based units.
pub fn readable(bytes: u64) -> String {
    let r = rank(bytes);
    if r == 0 {
        return format!("{bytes} bytes");
    }
    let v = bytes as f64 / 1024f64.powi(r as i32);
    if v < 10.0 {
        format!("{v:.2} {}", UNITS[r])
    } else if v < 100.0 {
        format!("{v:.1} {}", UNITS[r])
    } else {
        format!("{v:.0} {}", UNITS[r])
    }
}

/// The full InfoTip text for one folder.
pub fn tip(format: Format, bytes: u64, files: u64, show_files: bool, partial: bool) -> String {
    let mut s = match format {
        Format::Sortable => sortable(bytes),
        Format::Bytes => exact(bytes),
        Format::Readable => readable(bytes),
    };
    if show_files {
        s.push_str(&format!(" - {} files", crate::util::human_count(files)));
    }
    if partial {
        s.push_str(" (partial: some folders unreadable)");
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn samples() -> Vec<u64> {
        let mut v = vec![0u64, 1, 9, 10, 99, 100, 512, 999, 1000, 1023, 1024, 1025, 2047, 2048];
        for r in 1..6u32 {
            let b = 1024u64.pow(r);
            for k in [b - 1, b, b + 1, b * 2 - 1, b * 9, b * 10, b * 99, b * 100, b * 999, b * 1000, b * 1023, b * 1024 - 1] {
                v.push(k);
            }
        }
        // a deterministic spread
        let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
        for _ in 0..20_000 {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            let shift = x % 50;
            v.push((x >> 14) >> shift);
        }
        v.sort();
        v.dedup();
        v
    }

    #[test]
    fn sortable_text_order_matches_numeric_order() {
        let v = samples();
        for w in v.windows(2) {
            let (a, b) = (sortable(w[0]), sortable(w[1]));
            assert!(a <= b, "{} ({}) should sort before {} ({})", a, w[0], b, w[1]);
        }
    }

    #[test]
    fn bytes_text_order_matches_numeric_order() {
        let v: Vec<u64> = samples().into_iter().filter(|&b| b < 1_000_000_000_000_000).collect();
        for w in v.windows(2) {
            assert!(exact(w[0]) <= exact(w[1]), "{} vs {}", exact(w[0]), exact(w[1]));
        }
    }

    #[test]
    fn widths_are_fixed_per_class() {
        assert_eq!(sortable(0), "[0] 0000 B");
        assert_eq!(sortable(1023), "[0] 1023 B");
        assert_eq!(sortable(1024), "[1] 0001.00 KB");
        assert_eq!(sortable(13_321_456_789), "[3] 0012.41 GB");
        assert_eq!(sortable(1024 * 1024 * 1024 - 1), "[2] 1024.00 MB");
        assert_eq!(readable(13_321_456_789), "12.4 GB");
        assert_eq!(exact(13_321_456_789), "000,013,321,456,789 bytes");
    }
}
