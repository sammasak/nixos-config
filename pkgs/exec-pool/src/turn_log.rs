//! A turn's agent output, kept on the host that runs it and bounded to its tail.
//!
//! The agent step's stdout and stderr go, as they are produced, to segments `agent-<offset>.log` in the run's
//! directory, at most half the bound each, the two newest kept: the files never hold more than the bound and always
//! the last half of it at least. The runner hands the tail to the queue at each heartbeat (`Store::put_log`), which is
//! how `exec-pool logs` reads it from any host.

use std::fs::{self, File};
use std::io::{self, Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// The most a turn's log holds, on the host and in the queue (`turn_logs`, migration 0015).
pub const LOG_BYTES: u64 = 256 * 1024;

fn segment(dir: &Path, start: u64) -> PathBuf {
    dir.join(format!("agent-{start}.log"))
}

struct Open {
    file: File,
    start: u64,
    len: u64,
    previous: Option<u64>,
}

/// The writing end, shared by the threads that copy the step's streams.
pub struct Writer {
    dir: PathBuf,
    half: u64,
    open: Mutex<Open>,
}

impl Writer {
    /// Starts the log in `dir`, holding at most `bound` bytes (at least 2).
    ///
    /// # Errors
    /// What creating its first segment reports.
    pub fn create(dir: &Path, bound: u64) -> io::Result<Self> {
        Ok(Self {
            dir: dir.to_owned(),
            half: (bound / 2).max(1),
            open: Mutex::new(Open {
                file: File::create(segment(dir, 0))?,
                start: 0,
                len: 0,
                previous: None,
            }),
        })
    }

    /// Appends `buf`, starting a new segment whenever one is full and removing the one before the last.
    ///
    /// # Errors
    /// What writing, creating or removing a segment reports.
    pub fn write(&self, mut buf: &[u8]) -> io::Result<()> {
        let mut o = self
            .open
            .lock()
            .map_err(|_| io::Error::other("a log writer panicked"))?;
        while !buf.is_empty() {
            if o.len >= self.half {
                let start = o.start.saturating_add(o.len);
                o.file = File::create(segment(&self.dir, start))?;
                let current = o.start;
                if let Some(old) = o.previous.replace(current) {
                    fs::remove_file(segment(&self.dir, old))?;
                }
                (o.start, o.len) = (start, 0);
            }
            let room = usize::try_from(self.half.saturating_sub(o.len)).unwrap_or(usize::MAX);
            let (now, rest) = buf.split_at(room.min(buf.len()));
            o.file.write_all(now)?;
            o.len = o
                .len
                .saturating_add(u64::try_from(now.len()).unwrap_or(u64::MAX));
            buf = rest;
        }
        drop(o);
        Ok(())
    }
}

/// The log's tail in `dir`: the offset of its first byte in the whole output, and the bytes, at most [`LOG_BYTES`].
/// `None` when the turn wrote none (its agent step has not started).
///
/// # Errors
/// What listing or reading the directory reports.
pub fn read(dir: &Path) -> io::Result<Option<(u64, Vec<u8>)>> {
    let mut starts: Vec<u64> = fs::read_dir(dir)?
        .filter_map(|e| {
            let name = e.ok()?.file_name().into_string().ok()?;
            name.strip_prefix("agent-")?
                .strip_suffix(".log")?
                .parse()
                .ok()
        })
        .collect();
    starts.sort_unstable();
    let mut tail: Option<(u64, Vec<u8>)> = None;
    for &start in starts.iter().rev().take(2).rev() {
        let mut bytes = Vec::new();
        match File::open(segment(dir, start)) {
            Ok(f) => f.take(LOG_BYTES).read_to_end(&mut bytes)?,
            // the writer removed it since the listing: the newer one stands alone
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e),
        };
        tail = match tail {
            Some((s, mut held))
                if s.saturating_add(u64::try_from(held.len()).unwrap_or(u64::MAX)) == start =>
            {
                held.extend(bytes);
                Some((s, held))
            }
            _ => Some((start, bytes)),
        };
    }
    Ok(tail.map(|(s, mut bytes)| {
        let over = bytes
            .len()
            .saturating_sub(usize::try_from(LOG_BYTES).unwrap_or(usize::MAX));
        bytes.drain(..over);
        (
            s.saturating_add(u64::try_from(over).unwrap_or(u64::MAX)),
            bytes,
        )
    }))
}

#[cfg(test)]
mod tests {
    #![allow(
        clippy::unwrap_used,
        clippy::indexing_slicing,
        reason = "a failure is the test failing"
    )]

    use super::*;

    fn dir(name: &str) -> PathBuf {
        let d =
            std::env::temp_dir().join(format!("exec-pool-turn-log-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn the_log_keeps_its_tail_within_the_bound() {
        let d = dir("bound");
        assert_eq!(read(&d).unwrap(), None);
        let w = Writer::create(&d, 10).unwrap();
        let all: Vec<u8> = (0..=255u8).cycle().take(1000).collect();
        for chunk in all.chunks(7) {
            w.write(chunk).unwrap();
            let on_disk: u64 = fs::read_dir(&d)
                .unwrap()
                .map(|e| e.unwrap().metadata().unwrap().len())
                .sum();
            assert!(on_disk <= 10, "{on_disk} bytes on disk");
        }
        let (start, bytes) = read(&d).unwrap().unwrap();
        assert!(bytes.len() >= 5 && bytes.len() <= 10, "{}", bytes.len());
        assert_eq!(start, 1000 - u64::try_from(bytes.len()).unwrap());
        assert_eq!(bytes, all[all.len() - bytes.len()..]);
        assert_eq!(fs::read_dir(&d).unwrap().count(), 2);
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn a_short_log_is_read_whole_from_its_start() {
        let d = dir("short");
        let w = Writer::create(&d, LOG_BYTES).unwrap();
        w.write(b"turn started\n").unwrap();
        w.write(b"").unwrap();
        assert_eq!(read(&d).unwrap(), Some((0, b"turn started\n".to_vec())));
        fs::remove_dir_all(&d).unwrap();
    }
}
