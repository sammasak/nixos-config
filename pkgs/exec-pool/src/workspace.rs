//! Per-attempt workspaces in a reusable slot (#653).
//!
//! Each attempt gets its own HOME, checkout, tmp and output directories, mode 0700, under the guest user's home, and
//! the runner admits an attempt only to a home that `dev-env-reset@<slot>` has replaced since the slot's last attempt.
//!
//! Every attempt runs as the same guest UID, so the mode keeps out other users, not the next attempt: the reset is
//! what does that. It trashes the whole home, and with it anything an attempt left outside its workspace. The guest
//! can delete its own files but cannot replace its home's mount point, so the host-side [`HomeId`] proves a reset where
//! a marker in the home would not.

use std::fmt::Write as _;
use std::io;
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::RelPath;

/// Under the guest home; the first attempt after a reset creates it, so it exists only if one already ran.
pub const ROOT: &str = "attempts";

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum Error {
    #[error("the attempt id is empty")]
    AttemptId,
    #[error("guest home {0:?} must be absolute, with no trailing `/`")]
    Home(String),
    #[error("the argv is empty or its command {0:?} holds `=`, which env would read as a variable")]
    Command(String),
    #[error("the slot's home is the one its last attempt ran in: it was not reset")]
    NotReset,
}

/// The host's slot home directory by device and inode; a reset makes a new directory, while the old one stays
/// allocated in the trash, so the pair changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HomeId {
    pub dev: u64,
    pub ino: u64,
}

impl HomeId {
    /// # Errors
    /// The path cannot be read, or is a symlink or not a directory.
    pub fn of(path: &Path) -> io::Result<Self> {
        let m = path.symlink_metadata()?;
        if !m.is_dir() {
            return Err(io::Error::other(format!(
                "{} is not a directory",
                path.display()
            )));
        }
        Ok(Self {
            dev: m.dev(),
            ino: m.ino(),
        })
    }
}

/// Whether an attempt may start in a slot whose home is now `now`, given the home its last attempt ran in.
///
/// # Errors
/// [`Error::NotReset`] when the two are the same directory.
pub fn admit(last: Option<HomeId>, now: HomeId) -> Result<(), Error> {
    if last == Some(now) {
        Err(Error::NotReset)
    } else {
        Ok(())
    }
}

/// One attempt's directories in the guest, all absolute.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Workspace {
    root: String,
    dir: String,
}

impl Workspace {
    /// `guest_home/attempts/<hex of the attempt id>-<epoch>`: one path component whatever the id holds.
    ///
    /// # Errors
    /// An empty attempt id, or a guest home that is not absolute or ends in `/`.
    pub fn new(guest_home: &str, attempt_id: &str, lease_epoch: u64) -> Result<Self, Error> {
        if attempt_id.is_empty() {
            return Err(Error::AttemptId);
        }
        if !guest_home.starts_with('/') || guest_home.ends_with('/') || guest_home.contains('\0') {
            return Err(Error::Home(guest_home.to_owned()));
        }
        let root = format!("{guest_home}/{ROOT}");
        let mut dir = format!("{root}/");
        for b in attempt_id.bytes() {
            let _ = write!(dir, "{b:02x}");
        }
        let _ = write!(dir, "-{lease_epoch}");
        Ok(Self { root, dir })
    }

    #[must_use]
    pub fn dir(&self) -> &str {
        &self.dir
    }

    /// The attempt's HOME: its config, caches and agent state.
    #[must_use]
    pub fn home(&self) -> String {
        format!("{}/home", self.dir)
    }

    /// Where the task's repository is cloned.
    #[must_use]
    pub fn checkout(&self) -> String {
        format!("{}/work", self.dir)
    }

    #[must_use]
    pub fn tmp(&self) -> String {
        format!("{}/tmp", self.dir)
    }

    /// What the attempt hands back; the only directory the host should stage artifacts from.
    #[must_use]
    pub fn out(&self) -> String {
        format!("{}/out", self.dir)
    }

    /// The guest commands that create the workspace, run in order, stopping at the first that fails. The first fails
    /// when [`ROOT`] exists, so a home an attempt already used is refused before anything else is made in it; mkdir
    /// does not follow a symlink in a name's last component.
    #[must_use]
    pub fn create(&self, mkdir: &str) -> [Vec<String>; 2] {
        let s = |v: &[&str]| v.iter().map(|&x| x.to_owned()).collect::<Vec<_>>();
        [
            s(&[mkdir, "-m", "0700", "--", &self.root]),
            s(&[
                mkdir,
                "-m",
                "0700",
                "--",
                &self.dir,
                &self.home(),
                &self.checkout(),
                &self.tmp(),
                &self.out(),
            ]),
        ]
    }

    /// `argv` run in `workdir` under the checkout with this attempt's HOME and TMPDIR, through `env` (a store path).
    ///
    /// # Errors
    /// An empty argv, or a command holding `=`.
    pub fn run(&self, env: &str, workdir: &RelPath, argv: &[String]) -> Result<Vec<String>, Error> {
        let cmd = argv.first().ok_or_else(|| Error::Command(String::new()))?;
        if cmd.contains('=') {
            return Err(Error::Command(cmd.clone()));
        }
        let mut out = vec![
            env.to_owned(),
            "-C".to_owned(),
            format!("{}/{}", self.checkout(), workdir.as_str()),
            "--".to_owned(),
            format!("HOME={}", self.home()),
            format!("TMPDIR={}", self.tmp()),
        ];
        out.extend(argv.iter().cloned());
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ws() -> Result<Workspace, Error> {
        Workspace::new("/home/lukas", "a/../b", 3)
    }

    #[test]
    fn each_attempt_and_epoch_has_its_own_directory_under_the_root() -> Result<(), Error> {
        let w = ws()?;
        assert_eq!(w.dir(), "/home/lukas/attempts/612f2e2e2f62-3");
        assert_eq!(w.home(), "/home/lukas/attempts/612f2e2e2f62-3/home");
        assert_ne!(Workspace::new("/home/lukas", "a/../b", 4)?, w);
        assert_ne!(Workspace::new("/home/lukas", "a/../c", 3)?, w);
        Ok(())
    }

    #[test]
    fn refuses_an_empty_id_and_a_home_that_is_not_absolute() {
        assert_eq!(Workspace::new("/h", "", 1), Err(Error::AttemptId));
        for h in ["home", "/home/", ""] {
            assert_eq!(Workspace::new(h, "a", 1), Err(Error::Home(h.to_owned())));
        }
    }

    #[test]
    fn creation_makes_the_root_alone_first_and_everything_private() -> Result<(), Error> {
        let [root, rest] = ws()?.create("mkdir");
        assert_eq!(root, ["mkdir", "-m", "0700", "--", "/home/lukas/attempts"]);
        assert!(rest.iter().take(4).eq(root.iter().take(4)));
        assert_eq!(rest.len(), 9);
        assert!(
            rest.iter()
                .skip(4)
                .all(|d| d.starts_with("/home/lukas/attempts/612f2e2e2f62-3"))
        );
        Ok(())
    }

    #[test]
    fn the_command_runs_in_the_checkout_with_the_attempts_home_and_tmp()
    -> Result<(), Box<dyn std::error::Error>> {
        let w = ws()?;
        let workdir = RelPath::try_from("crates/x".to_owned())?;
        let argv = w.run("env", &workdir, &["cargo".to_owned(), "A=b".to_owned()])?;
        assert_eq!(
            argv,
            [
                "env",
                "-C",
                "/home/lukas/attempts/612f2e2e2f62-3/work/crates/x",
                "--",
                "HOME=/home/lukas/attempts/612f2e2e2f62-3/home",
                "TMPDIR=/home/lukas/attempts/612f2e2e2f62-3/tmp",
                "cargo",
                "A=b",
            ]
        );
        assert_eq!(
            w.run("env", &workdir, &[]),
            Err(Error::Command(String::new()))
        );
        assert_eq!(
            w.run("env", &workdir, &["X=1".to_owned()]),
            Err(Error::Command("X=1".to_owned()))
        );
        Ok(())
    }

    #[test]
    fn only_a_replaced_home_admits_the_next_attempt() -> io::Result<()> {
        let t = std::env::temp_dir().join(format!("exec-pool-ws-{}", std::process::id()));
        let (a, b) = (t.join("a"), t.join("b"));
        std::fs::create_dir_all(&a)?;
        std::fs::create_dir_all(&b)?;
        let first = HomeId::of(&a)?;
        assert_eq!(admit(None, first), Ok(()));
        assert_eq!(admit(Some(first), HomeId::of(&a)?), Err(Error::NotReset));
        // the reset's rename to the trash, then a new home where the old one was
        std::fs::rename(&a, t.join("trashed"))?;
        std::fs::rename(&b, &a)?;
        assert_eq!(admit(Some(first), HomeId::of(&a)?), Ok(()));
        std::os::unix::fs::symlink(t.join("trashed"), t.join("link"))?;
        assert!(HomeId::of(&t.join("link")).is_err());
        std::fs::remove_dir_all(&t)
    }
}
