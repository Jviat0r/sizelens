# SizeLens

Folder sizes in the normal Windows 10 File Explorer, so you can see them and sort folders by size.

```
Name            Comments
hotel-sparse    [3] 0003.00 GB
bravo           [2] 0012.00 MB
golf-denied     [1] 0977.77 KB
alpha           [1] 0128.75 KB
juliet          [0] 0100 B
charlie         [0] 0000 B
```

## Why it exists

Explorer leaves the **Size** column blank for folders. Right-click > Properties knows the size, but
that's one folder at a time. SizeLens measures the folders once, keeps the numbers in a plain text
file, and puts each folder's size where Explorer will show it: the **Comments** column (and the
tooltip when you hover a folder).

It's a small Rust program with no dependencies outside the standard library, plus a few PowerShell
scripts for install and uninstall. No admin rights needed.

## Why the Comments column and not the Size column

Since Windows Vista there's no supported way for an add-on to fill Explorer's Size column for
folders. The old column-handler API (IColumnProvider) was removed, and property handlers are
registered per file extension, which folders don't have. The only way into the Size column would be
hooking Explorer's code, and SizeLens doesn't do that.

## How it works

A folder can contain a `desktop.ini` with

```ini
[.ShellClassInfo]
InfoTip=[3] 0012.40 GB
```

Explorer shows a folder's `InfoTip` as its **Comments** property (System.Comment) and as the hover
tooltip. It only reads `desktop.ini` when the folder has the **Read-only** or **System** attribute,
so SizeLens sets Read-only on the folder (on folders Windows ignores Read-only for the files inside;
it's the standard "this folder is customized" flag). `desktop.ini` is made Hidden + System like the
ones Windows makes itself, so you won't see it unless you show protected OS files.

Everything SizeLens changes is recorded in an undo log, so `sizelens clean` can put it back exactly.

The Comments column sorts as text, not numbers, so the size is written in a form where text order
matches size order (next section).

## The format, and why it looks like that

| `format =` in config.txt | Example | Sorts right? |
|---|---|---|
| `sortable` (default) | `[3] 0012.40 GB` | Yes |
| `bytes` | `000,013,321,456,789 bytes` | Yes (up to 999 TB per folder) |
| `readable` | `12.4 GB` | **No** |

`sortable` explained: the digit in brackets is the size class, `0`=bytes `1`=KB `2`=MB `3`=GB
`4`=TB, then the number zero-padded to a fixed width. A GB folder always sorts above an MB folder,
and within a class the padding keeps `0850.00` above `0095.00`. I tested this against every
comparison Explorer could be using (plain, case-insensitive, "numbers in names" natural sort, the
Windows property-system comparison): 0 wrong pairs over 448 sizes from 0 B to 30 TB. `readable`
gets things like `9 bytes` > `10 bytes` and `1023 bytes` > `1.00 KB` wrong, which is why it isn't
the default. It's fine if you only want the tooltip.

`show_files = true` adds the file count: `[3] 0012.40 GB - 1,234 files`.

## What the number is

- **Size, not "Size on disk"**: the sum of every file's size, the same number as "Size" in
  Properties. Hidden and system files count.
- **Links aren't followed.** Junctions and symbolic links inside a folder aren't counted (they'd
  double-count, or loop). A junction directly in an opted-in folder doesn't get a size at all.
- **`desktop.ini` files aren't counted**, because they hold the size labels (counting them would
  change the numbers every time they're written). That's the only difference from Properties, a
  few hundred bytes per folder.
- **Every level gets a size** (`depth = all` in config.txt; set a number to stop lower). Skipped:
  hidden folders, names in `skip_names` (dot-folders like `.git`, `node_modules`, ...), git
  repositories (`git_repos = skip`, so desktop.ini never shows up in `git status`), and folders that
  can't be read. Sizes inside those still count toward their parents.
- **Unreadable folders** (access denied) are skipped, and the label says
  `(partial: some folders unreadable)`.
- Long paths (over 260 characters) and non-English names work.

## Install

You need Windows and Rust (`cargo`) to build it. No admin rights; nothing goes outside your user
account.

```powershell
git clone https://github.com/Jviat0r/sizelens.git
cd sizelens
powershell -ExecutionPolicy Bypass -File build.ps1               # builds bin\sizelens.exe + bin\sizelensw.exe
powershell -ExecutionPolicy Bypass -File install.ps1             # right-click entries
powershell -ExecutionPolicy Bypass -File install.ps1 -Startup    # ...plus the watcher at logon
powershell -ExecutionPolicy Bypass -File install.ps1 -AddCommentsColumn   # ...plus Comments as a default column
```

`build.ps1` runs `cargo build --release` and copies the two programs into `bin\`. If the watcher is
running, stop it first (`bin\sizelens.exe stop`), or Windows won't let the exe be replaced.

`install.ps1` writes only to HKCU (your user):

- `HKCU\Software\Classes\Directory\shell\SizeLens.Show` and `...\SizeLens.Remove`
- the same two under `HKCU\Software\Classes\Directory\Background\shell` (right-click the empty space
  inside a folder)
- with `-Startup`: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, value `SizeLens`
  (`bin\sizelensw.exe watch`, which runs with no window), and it starts the watcher right away
- with `-AddCommentsColumn`: per-user copies of the column defaults for 6 folder types under
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes`, with `System.Comment` added
  (`comments-column.ps1`). It first exports that key to
  `%LOCALAPPDATA%\SizeLens\backups\foldertypes-before-<time>.reg` and records what it created or
  changed in `comments-column.tsv`, which the undo reads. HKLM is only read. Restart Explorer after.

Nothing is copied anywhere else: the entries point at `bin\` in this folder, so leave the folder
where it is (or run `install.ps1` again after moving it).

## Use it

1. Right-click a folder (say `D:\Projects`) > **Show or refresh folder sizes**. A console window
   measures its subfolders and closes after 5 s. Or from a terminal:
   `bin\sizelens.exe here "D:\Projects"`. Used on a folder that is already inside an opted-in
   folder, it just re-measures that branch now (it doesn't opt it in a second time).
2. If the Comments column isn't there (see the one-time setup below), right-click any column header
   > **More...** > tick **Comments** > OK. Or on the ribbon: View > Add columns > Choose columns... >
   Comments.
3. Click the **Comments** header to sort. Click again for biggest first.

No F5 needed: a window that was already open catches up within about a minute (see
"Windows that are already open" below), a newly opened one right away.

### Commands

```
sizelens add <folder> [--allow-onedrive] [--allow-drive-root]   opt a folder in
sizelens scan <folder> | --all [--dry-run]                       measure + write the sizes
sizelens here <folder>                                           add + scan (inside an opted-in folder: re-measure)
sizelens clean <folder> | --all [--keep-root]                    undo everything there, and opt it out
sizelens status                                                  what's opted in, biggest folders, watcher
sizelens watch                                                   keep sizes current (stop: sizelens stop)
sizelens stop
sizelens fmt <bytes>...                                          show how a size is written
sizelens follow-up                                               (internal) do pending follow-up rewrites, then exit
```

Only folders listed in the config are ever touched. `scan` refuses anything else.

`sizelensw.exe` takes the same commands but has no console window; its output goes to
`%LOCALAPPDATA%\SizeLens\sizelens.log`. It's what runs at logon.

### Keeping sizes current

`sizelens watch` (or `sizelensw.exe watch` at logon) watches each opted-in folder with Windows' own
change notifications (ReadDirectoryChangesW). When something changes inside a subfolder it waits
until things go quiet (`debounce_seconds`, 10 by default) and re-measures **only that subfolder**.
Every `full_rescan_minutes` (6 hours by default) it re-measures everything, in case a change was
missed. It runs at background CPU and disk priority. In testing it used 0 ms of CPU over 10 s idle
and updated a folder 2 s after a 5 MB file landed in it. It also does the follow-up rewrites (one
per changed folder, `follow_up_seconds` after its last change) that let open Explorer windows catch
up. Without the watcher, sizes are only as fresh as your last scan.

## One-time Explorer setup (so Comments shows in every folder)

Explorer picks columns per folder type ("Optimize this folder for": General items, Documents,
Pictures, Music, Videos), and a folder whose view you saved before keeps its own columns.

**Easiest:** `powershell -ExecutionPolicy Bypass -File install.ps1 -AddCommentsColumn`, then restart
Explorer (Task Manager > Windows Explorer > Restart; your open folder windows close), or sign out and
back in. It adds Comments to your own (per-user) column defaults for General items, Documents,
Pictures, Music, Videos and Downloads. No admin, nothing outside your user, undone by uninstall.ps1.
What still wins over it:

- a folder whose view you saved (you changed its columns or sort there before): tick Comments there
  once (right-click a column header > More... > Comments), and
- "Apply to Folders" settings you made for a folder type. The script tells you which types have one
  and whether it already includes Comments.

**By hand**, once per folder type:

1. Open a folder SizeLens labelled. Right-click a column header > More... > tick **Comments** > OK.
2. View > Options > **View** tab > **Apply to Folders** > Yes.
3. If a folder of another type (say a photo folder) still has no Comments column, repeat 1 and 2 there.

Optional: set `folder_type = generic` in config.txt *before* the first scan. Every desktop.ini
SizeLens creates then marks its folder "General items", so step 2 done once covers all of them. The
trade-off: those folders stop auto-switching to the Pictures/Music/Videos layouts.

## Windows that are already open

A folder window that is already open shows a new size **within about a minute, by itself**. A newly
opened window shows it right away.

Why not instantly: Explorer ignores a desktop.ini change that happens within about 60 s after a
window last read that file (I measured this with the `tests\explorer-*.ps1` scripts). Nothing from
outside gets past that: not F5, not SHChangeNotify, not re-navigating the window to the same folder
or to its parent and back. A change made later than that is picked up. So after SizeLens changes a
label, it writes the same label once more 65 s later (`follow_up_seconds` in config.txt). The
watcher does that; after a one-off scan without the watcher, a hidden helper
(`sizelensw.exe follow-up`) does it and exits. That's also why F5 only works sometimes: it works
only when the window's last read is over a minute old.

## Files

All in `%LOCALAPPDATA%\SizeLens\`:

| File | What |
|---|---|
| `config.txt` | settings + the `root = ...` lines (the opted-in folders). Plain text, edit freely. |
| `sizes.tsv` | the size index: `path, bytes, files, folders, unreadable, links_skipped, scanned_at, root`, one line per folder |
| `managed.tsv` | the undo log: what SizeLens changed in each folder (attributes before, whether it created desktop.ini, a hash of what it wrote) |
| `backups\` | an exact copy of every desktop.ini that was there before SizeLens touched it |
| `sizelens.log` | output of the windowless watcher (and the follow-up helper) |
| `followup.tsv` | pending follow-up rewrites: when, and which folder. Gone when there are none. |
| `comments-column.tsv` | only after `install.ps1 -AddCommentsColumn`: the registry keys it created and values it changed (old value included) |
| `backups\foldertypes-before-*.reg` | only after `-AddCommentsColumn`: export of your FolderTypes key before it changed anything |

## What it refuses to touch

By default `add` refuses: `C:\Windows`, Program Files (both), ProgramData, `$Recycle.Bin`,
System Volume Information, Recovery; your user profile folder itself, `C:\Users`, other profiles,
anything in `AppData`; **OneDrive** folders (desktop.ini would sync to every device; override with
`--allow-onedrive`); **network** drives and `\\server` paths; CD/DVD drives; a **whole drive** like
`D:\` (override with `--allow-drive-root`); a junction or symlink (add the real folder instead).

While scanning an opted-in folder it also skips subfolders that are links, Hidden + System, or
match any of the rules above. Folders inside your profile, like `Downloads` or `Documents`, are
allowed.

## Uninstall and undo

- One folder: right-click it > **Remove folder sizes**, or `sizelens clean "D:\Projects"`.
- Everything: `sizelens clean --all`.
- Uninstall: `powershell -ExecutionPolicy Bypass -File uninstall.ps1 -CleanFolders` (cleans every
  folder, stops the watcher, removes the right-click and logon entries, and undoes
  `-AddCommentsColumn`; restart Explorer afterwards for that part). Add `-RemoveData` to also
  delete `%LOCALAPPDATA%\SizeLens`. It refuses to delete it while any folder still needs its backup.
  Then delete the SizeLens folder itself by hand.

What `clean` does in each folder:

- desktop.ini that SizeLens **created**: deleted.
- desktop.ini that **was already there** (custom icon, localized name, etc.): restored
  byte-for-byte from the backup, with its original attributes and modified time.
- If **you edited** desktop.ini after SizeLens wrote it (say, changed the folder icon), your edit is
  kept. Only the `InfoTip` line goes back to what it was, and the file stays if it has your settings
  in it.
- Read-only is removed from folders where SizeLens added it, and each folder's "Date modified" is
  put back.

SizeLens only ever edits the `InfoTip` line. `IconResource`, `LocalizedResourceName`, `[ViewState]`
and every other line keep their exact text, line endings and file encoding (UTF-16, UTF-8 or ANSI).

## Limitations

- It's the **Comments** column, not Size. `-AddCommentsColumn` (or Apply to Folders) makes it a
  default; folders with their own saved view still need it ticked once.
- Sizes are a snapshot: fresh if the watcher is running, otherwise as of the last scan.
- An Explorer window that is already open can show the old size for up to about 65 s after a change
  (Explorer's own blind spot, see above). Opening the folder again shows it at once.
- Folders get sizes, files don't (the Size column already has those).
- Folders that use the Comments/InfoTip for something else lose that text while SizeLens is on
  (it comes back with `clean`).
- Programs that sync or archive folders will see the extra hidden `desktop.ini` files.
- Windows 11 puts these right-click entries under "Show more options". I built and tested it on
  Windows 10 22H2 (19045) only.

## Build and test

```powershell
cargo build --release
cargo test                                                        # unit tests (format sort order, desktop.ini editing, config)
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1      # integration tests on a scratch tree only
powershell -ExecutionPolicy Bypass -File tests\comments-column-test.ps1   # -AddCommentsColumn on a scratch registry key
powershell -ExecutionPolicy Bypass -File tests\explorer-followup.ps1      # opens 2 Explorer windows on test-tree\r3 (closed after)
```

Run `cargo build --release` before `tests\run-tests.ps1`; it uses `target\release\sizelens.exe`.
The integration test builds `test-tree\` with known file sizes (junctions, an access-denied folder,
a 3 GB sparse file, a 359-character path, existing desktop.ini files) and uses `test-home\` instead
of `%LOCALAPPDATA%` (`SIZELENS_HOME`). Results go to `tests\results.txt`. With `SIZELENS_HOME` set,
the watcher and helper use their own mutex names, so tests run fine while the real watcher is
running. The Explorer scripts (`tests\explorer-*.ps1`) read windows through UI Automation and send no
clicks or keys.

CI (GitHub Actions, `windows-latest`) runs `cargo build --release` and `cargo test` on every push
and pull request.

## License

MIT. See [LICENSE](LICENSE).
