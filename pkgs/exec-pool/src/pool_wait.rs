//! `pool-wait`: in a pool slot, how a session's agent asks to be woken at a time with no message. It writes one
//! [`Wake`] line to `/session/cur/home/.pool-wait` (through a temporary file and a rename), which the pool takes after
//! the turn; the last call in a turn wins. It needs no queue access. Exit 0 written, 1 not, 2 usage.

use std::fs;
use std::path::Path;
use std::process::ExitCode;

use exec_pool::wake::{self, Wake};
use exec_pool::workspace::SESSION_HOME;
use jiff::ZonedDateTime;

const USAGE: &str = "usage: pool-wait --until HH:MM|RFC3339 [--note TEXT]
  the session's next turn starts at that time (HH:MM: the next one, local time; one passed under 6 h ago is
  refused, as likely meant in another zone) unless a message wakes it sooner;
  TEXT (1 to 4096 bytes) is what that turn is told. Prints what it wrote.";

fn wake(args: &[String]) -> Result<Wake, String> {
    let (mut until, mut note) = (None, None);
    let mut it = args.iter();
    while let Some(flag) = it.next() {
        let slot = match flag.as_str() {
            "--until" => &mut until,
            "--note" => &mut note,
            other => return Err(format!("unexpected {other:?}")),
        };
        let value = it.next().ok_or_else(|| format!("{flag} needs a value"))?;
        if slot.replace(value.clone()).is_some() {
            return Err(format!("{flag} given twice"));
        }
    }
    let until = until.ok_or("--until is required")?;
    let due_at = wake::due_at(&until, &ZonedDateTime::now()).map_err(|e| e.to_string())?;
    Wake::new(&due_at, note).map_err(|e| e.to_string())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let w = match wake(&args) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("pool-wait: {e}\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let file = Path::new(SESSION_HOME).join(wake::FILE);
    let tmp = file.with_extension("tmp");
    let written = serde_json::to_string(&w)
        .map_err(std::io::Error::other)
        .and_then(|line| fs::write(&tmp, format!("{line}\n")).map(|()| line))
        .and_then(|line| fs::rename(&tmp, &file).map(|()| line));
    match written {
        Ok(line) => {
            println!("{line}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("pool-wait: {}: {e}", file.display());
            ExitCode::FAILURE
        }
    }
}
