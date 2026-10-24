//! Minimal, byte-preserving desktop.ini editing. Only the `InfoTip` key in `[.ShellClassInfo]`
//! is ever touched; every other line keeps its exact text and line ending.

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Enc {
    /// FF FE + UTF-16LE (what Windows itself ships in desktop.ini files).
    Utf16Le,
    /// EF BB BF + UTF-8.
    Utf8Bom,
    /// No BOM: system code page. Kept byte-for-byte (each byte maps to one char).
    Ansi,
}

pub fn decode(bytes: &[u8]) -> (Enc, String) {
    if bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
        let units: Vec<u16> = bytes[2..]
            .chunks(2)
            .map(|c| u16::from_le_bytes([c[0], *c.get(1).unwrap_or(&0)]))
            .collect();
        (Enc::Utf16Le, String::from_utf16_lossy(&units))
    } else if bytes.len() >= 3 && bytes[..3] == [0xEF, 0xBB, 0xBF] {
        (Enc::Utf8Bom, String::from_utf8_lossy(&bytes[3..]).into_owned())
    } else {
        (Enc::Ansi, bytes.iter().map(|&b| b as char).collect())
    }
}

pub fn encode(enc: Enc, text: &str) -> Vec<u8> {
    match enc {
        Enc::Utf16Le => {
            let mut out = vec![0xFF, 0xFE];
            for u in text.encode_utf16() {
                out.extend_from_slice(&u.to_le_bytes());
            }
            out
        }
        Enc::Utf8Bom => {
            let mut out = vec![0xEF, 0xBB, 0xBF];
            out.extend_from_slice(text.as_bytes());
            out
        }
        Enc::Ansi => text
            .chars()
            .map(|c| if (c as u32) < 256 { c as u32 as u8 } else { b'?' })
            .collect(),
    }
}

/// A desktop.ini SizeLens creates from scratch: UTF-16LE with BOM, CRLF.
/// With `generic`, also pins the folder type to "General items", the same [ViewState] lines
/// Explorer writes for Customize > Optimize this folder for > General items.
pub fn new_file(tip: &str, generic: bool) -> Vec<u8> {
    let mut s = format!("[.ShellClassInfo]\r\nInfoTip={tip}\r\n");
    if generic {
        s.push_str("[ViewState]\r\nMode=\r\nVid=\r\nFolderType=Generic\r\n");
    }
    encode(Enc::Utf16Le, &s)
}

const SECTION: &str = "[.ShellClassInfo]";
const KEY: &str = "InfoTip";

fn lines(text: &str) -> Vec<String> {
    text.split_inclusive('\n').map(|s| s.to_string()).collect()
}

fn body(line: &str) -> &str {
    line.trim_end_matches(['\r', '\n'])
}

fn ending(line: &str) -> &str {
    &line[body(line).len()..]
}

fn eol_of(text: &str) -> &'static str {
    if text.contains("\r\n") || !text.contains('\n') {
        "\r\n"
    } else {
        "\n"
    }
}

fn is_header(line: &str) -> bool {
    body(line).trim_start().starts_with('[')
}

/// (header index, end index exclusive) of [.ShellClassInfo].
fn section(ls: &[String]) -> Option<(usize, usize)> {
    let h = ls
        .iter()
        .position(|l| body(l).trim().eq_ignore_ascii_case(SECTION))?;
    let end = ls[h + 1..]
        .iter()
        .position(|l| is_header(l))
        .map(|i| h + 1 + i)
        .unwrap_or(ls.len());
    Some((h, end))
}

fn is_key(line: &str, key: &str) -> bool {
    let b = body(line).trim_start();
    if b.starts_with(';') {
        return false;
    }
    match b.split_once('=') {
        Some((k, _)) => k.trim().eq_ignore_ascii_case(key),
        None => false,
    }
}

fn key_index(ls: &[String], sec: (usize, usize)) -> Option<usize> {
    (sec.0 + 1..sec.1).find(|&i| is_key(&ls[i], KEY))
}

pub fn has_section(text: &str) -> bool {
    section(&lines(text)).is_some()
}

/// The full `InfoTip=...` line (without its line ending), if present.
pub fn infotip_line(text: &str) -> Option<String> {
    let ls = lines(text);
    let sec = section(&ls)?;
    key_index(&ls, sec).map(|i| body(&ls[i]).to_string())
}

pub fn infotip_value(text: &str) -> Option<String> {
    infotip_line(text).and_then(|l| l.split_once('=').map(|(_, v)| v.trim().to_string()))
}

/// Put `raw_line` (e.g. `InfoTip=...`) in [.ShellClassInfo], replacing any InfoTip line.
fn put_line(text: &str, raw_line: &str) -> String {
    let eol = eol_of(text);
    let mut ls = lines(text);
    match section(&ls) {
        Some(sec) => {
            if let Some(i) = key_index(&ls, sec) {
                let end = ending(&ls[i]).to_string();
                ls[i] = format!("{raw_line}{end}");
            } else {
                if ending(&ls[sec.0]).is_empty() {
                    ls[sec.0].push_str(eol);
                }
                ls.insert(sec.0 + 1, format!("{raw_line}{eol}"));
            }
        }
        None => {
            if let Some(last) = ls.last_mut() {
                if ending(last).is_empty() {
                    last.push_str(eol);
                }
            }
            ls.push(format!("{SECTION}{eol}"));
            ls.push(format!("{raw_line}{eol}"));
        }
    }
    ls.concat()
}

pub fn set_infotip(text: &str, value: &str) -> String {
    put_line(text, &format!("{KEY}={value}"))
}

/// Remove the InfoTip line. If that leaves [.ShellClassInfo] with no keys and
/// `drop_empty_section` is set, remove the header too.
pub fn remove_infotip(text: &str, drop_empty_section: bool) -> String {
    let mut ls = lines(text);
    let Some(sec) = section(&ls) else {
        return text.to_string();
    };
    let Some(i) = key_index(&ls, sec) else {
        return text.to_string();
    };
    ls.remove(i);
    if drop_empty_section {
        let sec = section(&ls).unwrap();
        let empty = (sec.0 + 1..sec.1).all(|j| body(&ls[j]).trim().is_empty());
        if empty {
            ls.drain(sec.0..sec.1);
        }
    }
    ls.concat()
}

/// Undo SizeLens's InfoTip change in `current`, using the original file as the reference,
/// while keeping any other edits made since. (Used only when the file changed after SizeLens
/// wrote it; otherwise the original bytes are restored as they were.)
pub fn revert(current: &str, original: &str) -> String {
    match infotip_line(original) {
        Some(line) => put_line(current, &line),
        None => {
            let mut out = remove_infotip(current, !has_section(original));
            if !original.is_empty() && !original.ends_with('\n') {
                // The original's last line had no line break; SizeLens added one before its
                // own line. Take it back.
                let eol = eol_of(&out);
                if out.ends_with(eol) {
                    out.truncate(out.len() - eol.len());
                }
            }
            out
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CASES: &[&str] = &[
        "",
        "[.ShellClassInfo]\r\nIconResource=C:\\x.ico,0\r\n",
        "[.ShellClassInfo]\r\nIconResource=C:\\x.ico,0\r\nInfoTip=old tip\r\n[ViewState]\r\nMode=\r\n",
        "[ViewState]\nMode=\nVid=\n",
        "[ViewState]\r\nFolderType=Pictures",
        "[.ShellClassInfo]",
        "; comment\r\n[.shellclassinfo]\r\nLocalizedResourceName=@%SystemRoot%\\system32\\shell32.dll,-21770\r\ninfotip = Spaced Old\r\n",
    ];

    #[test]
    fn set_then_revert_is_identity() {
        for c in CASES {
            let set = set_infotip(c, "[3] 0012.40 GB");
            assert_eq!(infotip_value(&set).as_deref(), Some("[3] 0012.40 GB"), "case {c:?}");
            let back = revert(&set, c);
            assert_eq!(&back, c, "case {c:?} -> {set:?}");
        }
    }

    #[test]
    fn other_lines_untouched() {
        let c = CASES[2];
        let set = set_infotip(c, "X");
        assert!(set.contains("IconResource=C:\\x.ico,0\r\n"));
        assert!(set.contains("[ViewState]\r\nMode=\r\n"));
        assert_eq!(set.matches("InfoTip").count(), 1);
    }

    #[test]
    fn revert_keeps_later_user_edits() {
        let orig = "[.ShellClassInfo]\r\nIconResource=a.ico,0\r\n";
        let ours = set_infotip(orig, "[1] 0002.00 KB");
        let edited = ours.replace("IconResource=a.ico,0", "IconResource=b.ico,3");
        let back = revert(&edited, orig);
        assert_eq!(back, "[.ShellClassInfo]\r\nIconResource=b.ico,3\r\n");
    }

    #[test]
    fn encodings_roundtrip() {
        let t = "[.ShellClassInfo]\r\nInfoTip=caf\u{e9}\r\n";
        for e in [Enc::Utf16Le, Enc::Utf8Bom, Enc::Ansi] {
            let b = encode(e, t);
            assert_eq!(decode(&b), (e, t.to_string()));
        }
        let raw: Vec<u8> = vec![0x5B, 0xE9, 0xFF, 0x0A];
        let (e, s) = decode(&raw);
        assert_eq!(encode(e, &s), raw);
    }
}
