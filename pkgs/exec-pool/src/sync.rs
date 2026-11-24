//! A parked session's tree between its host and the always-on store (modules/homelab/exec-pool-store.nix), laid out
//! there as here: `<hex of the task id>/tree/` and its `generation` mark beside it.
//!
//! The store's files belong to its sync user, which keeps each file's owner and mode in rsync's fake-super xattrs, so
//! it can always read, replace and delete what it holds. A pull restores the modes and gives the tree to the
//! receiving slot home's owner. Links are copied as links, never followed.

use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Where the store is, seen from this host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Depot {
    /// On this host: its directory, and its sync user as `chown` reads it (`user:group`).
    Local { root: PathBuf, owner: String },
    /// On another host, through `ssh` (the remote shell, one word per argument) as `dest` (`user@address`), whose
    /// forced command is rrsync confined to the store.
    Remote { dest: String, ssh: String },
}

/// The tree's generation mark, root's: the lease epoch of the turn that last parked it here.
pub const GENERATION: &str = "generation";

/// The I/O timeout of one transfer, in seconds.
const IO_SECS: u32 = 120;
/// The longest one transfer may take, in minutes: a drain has ten before the poweroff.
const STOP_AFTER_MINS: u32 = 5;

impl Depot {
    /// `<hex>/<rel>` in the store, as rsync names it.
    fn at(&self, hex: &str, rel: &str) -> String {
        match self {
            Self::Local { root, .. } => format!("{}/{hex}/{rel}", root.display()),
            Self::Remote { dest, .. } => format!("{dest}:{hex}/{rel}"),
        }
    }

    fn rsync(&self, rsync: &str) -> Vec<String> {
        let mut argv: Vec<String> = [
            rsync,
            "-aH",
            "--numeric-ids",
            "--delete",
            "--mkpath",
            &format!("--timeout={IO_SECS}"),
            &format!("--stop-after={STOP_AFTER_MINS}"),
        ]
        .map(str::to_owned)
        .into();
        if let Self::Remote { ssh, .. } = self {
            argv.extend(["-e".to_owned(), ssh.clone()]);
        }
        argv
    }

    /// The transfer of `from` (a directory's contents when it ends in `/`) into the store at `<hex>/<rel>`; the store
    /// side records owners and modes as fake-super.
    #[must_use]
    pub fn push_argv(&self, rsync: &str, from: &Path, hex: &str, rel: &str) -> Vec<String> {
        let mut argv = self.rsync(rsync);
        // a key the agent copied in stays on its host; the slot's own is a link outside the tree
        argv.extend(["-M--fake-super", "--exclude=/home/.ssh/"].map(str::to_owned));
        argv.extend([from.display().to_string(), self.at(hex, rel)]);
        argv
    }

    /// The transfer of the store's `<hex>/` into `into`, everything owned by `owner` (`uid:gid`), the modes as the
    /// store recorded them.
    #[must_use]
    pub fn pull_argv(&self, rsync: &str, hex: &str, into: &Path, owner: (u32, u32)) -> Vec<String> {
        let mut argv = self.rsync(rsync);
        // a local copy's --fake-super is both sides': --super keeps it off the receiving one
        argv.extend(match self {
            Self::Local { .. } => ["--fake-super".to_owned(), "-M--super".to_owned()].to_vec(),
            Self::Remote { .. } => ["-M--fake-super".to_owned()].to_vec(),
        });
        argv.extend([
            format!("--chown={}:{}", owner.0, owner.1),
            self.at(hex, ""),
            format!("{}/", into.display()),
        ]);
        argv
    }
}

/// Removes `path`, a copy from the store, read-only directories in it included; links are removed, not followed.
fn clear(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    fn open(p: &Path) -> std::io::Result<()> {
        if p.symlink_metadata()?.is_dir() {
            fs::set_permissions(p, fs::Permissions::from_mode(0o700))?;
            for e in fs::read_dir(p)? {
                open(&e?.path())?;
            }
        }
        Ok(())
    }
    match path.symlink_metadata() {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
        Ok(_) => open(path).and_then(|()| fs::remove_dir_all(path)),
    }
}

fn as_root() -> bool {
    use std::os::unix::fs::MetadataExt as _;
    fs::metadata("/proc/self").is_ok_and(|m| m.uid() == 0)
}

fn run(argv: &[String]) -> Result<(), String> {
    let (program, rest) = argv.split_first().ok_or("an empty argv")?;
    let out = Command::new(program)
        .args(rest)
        .output()
        .map_err(|e| format!("{program}: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!(
            "{} ({}): {}",
            argv.join(" "),
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

/// The generation mark in `dir`, if it holds one that reads as a number.
#[must_use]
pub fn generation(dir: &Path) -> Option<u64> {
    fs::read_to_string(dir.join(GENERATION))
        .ok()
        .and_then(|s| s.trim().parse().ok())
}

/// The store's generation mark for `hex`, read through `probe` (a scratch directory beside the tree); `None` when the
/// store holds none that reads as a number, or cannot be read.
fn stored_generation(rsync: &str, depot: &Depot, hex: &str, probe: &Path) -> Option<u64> {
    let _ = fs::remove_dir_all(probe);
    let mut argv = depot.rsync(rsync);
    argv.extend(match depot {
        Depot::Local { .. } => vec!["--fake-super".to_owned(), "-M--super".to_owned()],
        Depot::Remote { .. } => vec!["-M--fake-super".to_owned()],
    });
    argv.extend([depot.at(hex, GENERATION), format!("{}/", probe.display())]);
    let got = run(&argv).ok().and_then(|()| generation(probe));
    let _ = fs::remove_dir_all(probe);
    got
}

/// Copies the task's directory `dir` (its `tree/` and the `generation` mark, at `epoch`) to the store as `hex`.
///
/// A store copy from a later generation is left alone, so a run that lost its lease never replaces its successor's.
/// The store's mark is blanked first and written last, so a push that stops partway leaves a mark no pull accepts.
///
/// # Errors
/// A later generation in the store, or what a transfer, or on a local store the hand-over to its sync user (`chown`),
/// reports.
pub fn push(
    (rsync, chown): (&str, &str),
    depot: &Depot,
    (dir, hex): (&Path, &str),
    epoch: u64,
) -> Result<(), String> {
    if let Some(g) = stored_generation(rsync, depot, hex, &dir.join("probe")).filter(|g| *g > epoch)
    {
        return Err(format!(
            "the store holds generation {g} of {hex}, later than {epoch}"
        ));
    }
    let blank = dir.join(format!("{GENERATION}.blank"));
    fs::write(&blank, "").map_err(|e| format!("{}: {e}", blank.display()))?;
    let pushed = run(&depot.push_argv(rsync, &blank, hex, GENERATION))
        .and_then(|()| run(&depot.push_argv(rsync, &dir.join("tree/"), hex, "tree/")))
        .and_then(|()| run(&depot.push_argv(rsync, &dir.join(GENERATION), hex, GENERATION)));
    let _ = fs::remove_file(&blank);
    // even after a failure: whatever reached a local store is its sync user's to replace
    let handed = match depot {
        Depot::Local { root, owner } if root.join(hex).symlink_metadata().is_ok() => run(&[
            chown.to_owned(),
            "-hR".to_owned(),
            owner.clone(),
            root.join(hex).display().to_string(),
        ]),
        _ => Ok(()),
    };
    pushed.and(handed)
}

/// Refuses what root must not take over from the store, whose files another host wrote: anything but directories,
/// regular files and links, and set-id bits. Links are not followed.
fn plain(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::{FileTypeExt as _, PermissionsExt as _};
    let m = path
        .symlink_metadata()
        .map_err(|e| format!("{}: {e}", path.display()))?;
    let t = m.file_type();
    if t.is_block_device()
        || t.is_char_device()
        || t.is_fifo()
        || t.is_socket()
        || (!t.is_symlink() && m.permissions().mode() & 0o6000 != 0)
    {
        return Err(format!(
            "{}: a device, fifo, socket or set-id file",
            path.display()
        ));
    }
    if t.is_dir() {
        for e in fs::read_dir(path).map_err(|e| format!("{}: {e}", path.display()))? {
            plain(&e.map_err(|e| format!("{}: {e}", path.display()))?.path())?;
        }
    }
    Ok(())
}

/// Replaces the task's tree in `dir` with the store's copy of `hex` and writes its generation mark; the generation
/// it took.
///
/// That is `want` or a later one (a turn that ran after the last park), owned by `owner` with the tree's own
/// directory root's 0711. The copy lands in `dir/incoming` first and is used only when the store's mark is the same
/// after the copy as in it, as a push that began meanwhile blanks it: a pull that fails leaves the tree as it was.
///
/// # Errors
/// What the transfer reports, a store mark before `want` or that moved, what [`plain`] refuses, or what moving the
/// copy into place reports.
pub fn pull(
    rsync: &str,
    depot: &Depot,
    (dir, hex): (&Path, &str),
    want: u64,
    owner: (u32, u32),
) -> Result<u64, String> {
    use std::os::unix::fs::{DirBuilderExt as _, PermissionsExt as _};
    let io = |p: &Path| {
        let p = p.display().to_string();
        move |e: std::io::Error| format!("{p}: {e}")
    };
    let incoming = dir.join("incoming");
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(io(dir))?;
    clear(&incoming).map_err(io(&incoming))?;
    let taken = run(&depot.pull_argv(rsync, hex, &incoming, owner)).and_then(|()| {
        let got = generation(&incoming).filter(|g| *g >= want);
        let after = stored_generation(rsync, depot, hex, &dir.join("probe"));
        match got {
            Some(g) if after == Some(g) => Ok(g),
            _ => Err(format!(
                "the store held generation {:?} of {hex}, then {after:?}; this turn needs {want}",
                generation(&incoming)
            )),
        }
    });
    let new = incoming.join("tree");
    let taken = taken.and_then(|g| {
        if !new.symlink_metadata().is_ok_and(|m| m.is_dir()) {
            return Err(format!("{}: not a directory", new.display()));
        }
        plain(&new).map(|()| g)
    });
    let got = match taken {
        Ok(g) => g,
        Err(e) => {
            let _ = clear(&incoming);
            return Err(e);
        }
    };
    let tree = dir.join("tree");
    // a test, as its own user, keeps the owner it has
    if as_root() {
        std::os::unix::fs::lchown(&new, Some(0), Some(0)).map_err(io(&new))?;
    }
    fs::set_permissions(&new, fs::Permissions::from_mode(0o711)).map_err(io(&new))?;
    let old = incoming.join("old");
    if tree.symlink_metadata().is_ok() {
        fs::rename(&tree, &old).map_err(io(&tree))?;
    }
    fs::rename(&new, &tree).map_err(io(&tree))?;
    fs::write(dir.join(GENERATION), got.to_string()).map_err(io(dir))?;
    clear(&incoming).map_err(io(&incoming))?;
    Ok(got)
}

/// Adds one transfer to the counter `exec_pool_store_transfers_total{op, result}` in the textfile `file`, which holds
/// nothing else, rewritten whole.
///
/// # Errors
/// What writing it reports.
pub fn count(file: &Path, op: &str, ok: bool) -> std::io::Result<()> {
    const NAME: &str = "exec_pool_store_transfers_total";
    let key = format!(
        "{NAME}{{op=\"{op}\",result=\"{}\"}}",
        if ok { "ok" } else { "failed" }
    );
    let mut counts: std::collections::BTreeMap<String, u64> = fs::read_to_string(file)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.rsplit_once(' '))
        .filter(|(k, _)| k.starts_with(NAME))
        .filter_map(|(k, v)| Some((k.to_owned(), v.parse().ok()?)))
        .collect();
    let n = counts.entry(key).or_default();
    *n = n.saturating_add(1);
    let mut text = format!(
        "# HELP {NAME} Session tree transfers with the store, by direction and result.\n# TYPE {NAME} counter\n"
    );
    for (k, v) in &counts {
        let _ = writeln!(text, "{k} {v}");
    }
    let tmp = file.with_extension("tmp");
    fs::write(&tmp, text)?;
    fs::rename(&tmp, file)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn remote() -> Depot {
        Depot::Remote {
            dest: "exec-pool-sync@192.168.10.2".to_owned(),
            ssh: "/bin/ssh -i /etc/ssh/ssh_host_ed25519_key".to_owned(),
        }
    }

    #[test]
    fn a_push_keeps_links_and_hard_links_and_records_modes_on_the_store_side() {
        let local = Depot::Local {
            root: PathBuf::from("/var/lib/de/.sessions-store"),
            owner: "exec-pool-sync:exec-pool-sync".to_owned(),
        };
        assert_eq!(
            local.push_argv("rsync", Path::new("/s/74/tree/"), "74", "tree/"),
            [
                "rsync",
                "-aH",
                "--numeric-ids",
                "--delete",
                "--mkpath",
                "--timeout=120",
                "--stop-after=5",
                "-M--fake-super",
                "--exclude=/home/.ssh/",
                "/s/74/tree/",
                "/var/lib/de/.sessions-store/74/tree/"
            ]
        );
        let argv = remote().push_argv("rsync", Path::new("/s/74/generation"), "74", GENERATION);
        assert_eq!(
            argv.get(7..).unwrap_or_default(),
            [
                "-e",
                "/bin/ssh -i /etc/ssh/ssh_host_ed25519_key",
                "-M--fake-super",
                "--exclude=/home/.ssh/",
                "/s/74/generation",
                "exec-pool-sync@192.168.10.2:74/generation"
            ]
        );
        assert!(
            !argv.iter().any(|a| a == "-L" || a.starts_with("--copy")),
            "a link is copied as a link"
        );
    }

    #[test]
    fn a_pull_restores_the_modes_and_gives_the_tree_to_the_slot_owner() {
        let argv = remote().pull_argv("rsync", "74", Path::new("/s/74/incoming"), (1000, 100));
        assert_eq!(
            argv.get(9..).unwrap_or_default(),
            [
                "-M--fake-super",
                "--chown=1000:100",
                "exec-pool-sync@192.168.10.2:74/",
                "/s/74/incoming/"
            ]
        );
        let local = Depot::Local {
            root: PathBuf::from("/st"),
            owner: "u:g".to_owned(),
        };
        assert_eq!(
            local
                .pull_argv("rsync", "74", Path::new("/s/74/incoming"), (1, 2))
                .get(7..)
                .unwrap_or_default(),
            [
                "--fake-super",
                "-M--super",
                "--chown=1:2",
                "/st/74/",
                "/s/74/incoming/"
            ]
        );
    }

    #[test]
    fn transfers_are_counted_by_direction_and_result() -> std::io::Result<()> {
        let dir = std::env::temp_dir().join(format!("exec-pool-count-{}", std::process::id()));
        fs::create_dir_all(&dir)?;
        let file = dir.join("c.prom");
        count(&file, "push", true)?;
        count(&file, "push", true)?;
        count(&file, "pull", false)?;
        let text = fs::read_to_string(&file)?;
        assert!(text.contains("exec_pool_store_transfers_total{op=\"push\",result=\"ok\"} 2\n"));
        assert!(
            text.contains("exec_pool_store_transfers_total{op=\"pull\",result=\"failed\"} 1\n")
        );
        assert!(text.contains("# TYPE exec_pool_store_transfers_total counter\n"));
        fs::remove_dir_all(&dir)
    }
}
