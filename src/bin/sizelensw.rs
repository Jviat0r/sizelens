//! Windowless SizeLens (no console window), for running the watcher at logon.
//! Same commands as sizelens.exe; output goes to <data folder>\sizelens.log.
#![windows_subsystem = "windows"]

fn main() {
    let dir = sizelens::util::data_dir();
    let _ = std::fs::create_dir_all(&dir);
    if let Ok(f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("sizelens.log"))
    {
        sizelens::log::to_file(f);
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(sizelens::cli::run(&args));
}
