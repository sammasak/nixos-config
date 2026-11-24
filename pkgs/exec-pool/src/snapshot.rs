//! A session's work between turns is its remote's, never a host's.
//!
//! The agent commits and pushes `pool/<task id>` itself, through the repository's own hooks. What it left
//! uncommitted at a park (tracked changes and untracked files, not ignored ones) the helper keeps as one snapshot
//! commit made with git plumbing, its parent the checkout's HEAD, and pushes to [`wip_ref`], overwritten at every
//! park and removed by a park that leaves nothing uncommitted. The next turn, on any host, clones the repository into
//! an empty checkout and puts the branch, and then the snapshot as uncommitted changes, back ([`Resume`]).
//!
//! The snapshot ref is outside `refs/heads`: no branch, so no pull request, no push-triggered CI and nothing to merge.
//! Every argv here runs in the guest as its user, through the slot's proxy like the clone, and reads no global git
//! config.

use crate::{TaskSpec, agent};

/// Where a session's snapshot is on its remote: `refs/pool-wip/<task id>`.
///
/// # Errors
/// The task id [`agent::branch`] refuses.
pub fn wip_ref(task: &TaskSpec) -> Result<String, agent::Error> {
    agent::branch(task).map(|_| format!("refs/pool-wip/{}", task.id))
}

/// The guest's git, run through `env` with no global config, in `checkout`.
#[derive(Debug, Clone, Copy)]
pub struct Git<'a> {
    pub env: &'a str,
    pub git: &'a str,
    pub checkout: &'a str,
}

impl Git<'_> {
    fn argv(&self, vars: &[&str], args: &[&str]) -> Vec<String> {
        let mut v = vec![
            self.env.to_owned(),
            "GIT_CONFIG_GLOBAL=/dev/null".to_owned(),
            "GIT_TERMINAL_PROMPT=0".to_owned(),
        ];
        v.extend(vars.iter().map(|&s| s.to_owned()));
        v.extend([
            self.git.to_owned(),
            "-C".to_owned(),
            self.checkout.to_owned(),
        ]);
        v.extend(args.iter().map(|&s| s.to_owned()));
        v
    }

    /// The remote's commits for the task's branch and its snapshot, for [`listed`]; it needs no checkout.
    #[must_use]
    pub fn list(&self, repo: &str, branch: &str, wip: &str) -> Vec<String> {
        [
            self.env,
            "GIT_CONFIG_GLOBAL=/dev/null",
            "GIT_TERMINAL_PROMPT=0",
            self.git,
            "ls-remote",
            "--",
            repo,
            &format!("refs/heads/{branch}"),
            wip,
        ]
        .map(str::to_owned)
        .to_vec()
    }

    /// The commands that make the snapshot's tree in a scratch `index` (a path outside the checkout): the index from
    /// HEAD, so a tracked file an ignore rule matches stays, then every change and untracked file but the ignored
    /// ones, then the tree, which the last one prints.
    #[must_use]
    pub fn tree(&self, index: &str) -> [Vec<String>; 3] {
        let var = format!("GIT_INDEX_FILE={index}");
        [
            self.argv(&[&var], &["read-tree", "HEAD"]),
            self.argv(&[&var], &["add", "--all"]),
            self.argv(&[&var], &["write-tree"]),
        ]
    }

    /// Prints HEAD's commit, then its tree.
    #[must_use]
    pub fn head(&self) -> Vec<String> {
        self.argv(&[], &["rev-parse", "HEAD", "HEAD^{tree}"])
    }

    /// Prints the snapshot commit of `tree` on HEAD.
    #[must_use]
    pub fn commit(&self, tree: &str, message: &str) -> Vec<String> {
        self.argv(&[], &["commit-tree", tree, "-p", "HEAD", "-m", message])
    }

    /// Replaces the snapshot with `commit`, or removes it with `None`. The checkout's hooks are not run: they gate
    /// code bound for a branch, and this ref is none (see the module doc).
    #[must_use]
    pub fn push(&self, commit: Option<&str>, wip: &str) -> Vec<String> {
        let spec = commit.map_or_else(|| format!(":{wip}"), |c| format!("+{c}:{wip}"));
        self.argv(
            &[],
            &[
                "-c",
                "core.hooksPath=/dev/null",
                "push",
                "--quiet",
                "origin",
                &spec,
            ],
        )
    }
}

/// The commit `ls_remote`, the output of [`Git::list`], shows for the full ref name `name`.
#[must_use]
pub fn listed(ls_remote: &str, name: &str) -> Option<String> {
    ls_remote
        .lines()
        .filter_map(|l| l.split_once('\t'))
        .find(|(_, r)| *r == name)
        .map(|(sha, _)| sha.to_owned())
}

/// What a park does on the remote.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Plan {
    /// The branch holds the whole tree and there is no snapshot: nothing.
    Clean,
    /// The branch holds the whole tree: remove the last park's snapshot, which the next turn would restore.
    Clear,
    /// Commit and push the snapshot: something is uncommitted, or committed and not pushed.
    Snapshot,
}

/// The park's [`Plan`] from the remote's `branch` and `wip` commits, the checkout's `head` and its tree, and `tree`,
/// the tree [`Git::tree`] made of everything not ignored.
#[must_use]
pub fn plan(
    (branch, wip): (Option<&str>, Option<&str>),
    (head, head_tree): (&str, &str),
    tree: &str,
) -> Plan {
    match (tree == head_tree && branch == Some(head), wip) {
        (false, _) => Plan::Snapshot,
        (true, Some(_)) => Plan::Clear,
        (true, None) => Plan::Clean,
    }
}

/// How a turn's fresh clone gets back to where the last park left it, from the remote's `branch` and `wip` commits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Resume {
    /// Nothing pushed yet: the branch is made at the task's rev, as on its first turn.
    Rev,
    /// The branch at its pushed commit.
    Branch(String),
    /// The snapshot: the branch at its parent, its tree in the working tree.
    Snapshot(String),
}

impl Resume {
    #[must_use]
    pub fn of(branch: Option<String>, wip: Option<String>) -> Self {
        match (branch, wip) {
            (_, Some(s)) => Self::Snapshot(s),
            (Some(b), None) => Self::Branch(b),
            (None, None) => Self::Rev,
        }
    }

    /// After the clone, each under its step's unit name: the checkout of `branch` (at `rev` for [`Resume::Rev`]),
    /// and for a snapshot first its fetch and after it the restore of its tree into the working tree alone, removing
    /// what it does not hold, so the index and HEAD stay the parent's and the snapshot reads as uncommitted changes.
    #[must_use]
    pub fn steps(
        &self,
        g: &Git<'_>,
        (branch, rev, wip): (&str, &str, &str),
    ) -> Vec<(&'static str, Vec<String>)> {
        let checkout = |at: &str, flag| g.argv(&[], &["checkout", "--quiet", flag, branch, at]);
        match self {
            Self::Rev => vec![("exec-pool-checkout", checkout(rev, "-b"))],
            Self::Branch(at) => vec![("exec-pool-checkout", checkout(at, "-B"))],
            Self::Snapshot(at) => vec![
                (
                    "exec-pool-fetch",
                    g.argv(&[], &["fetch", "--quiet", "origin", wip]),
                ),
                ("exec-pool-checkout", checkout(&format!("{at}^"), "-B")),
                (
                    "exec-pool-restore",
                    g.argv(
                        &[],
                        &[
                            "restore",
                            "--source",
                            at,
                            "--worktree",
                            "--no-overlay",
                            "--",
                            ":/",
                        ],
                    ),
                ),
            ],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn g() -> Git<'static> {
        Git {
            env: "env",
            git: "git",
            checkout: "/session/cur/work",
        }
    }

    #[test]
    fn a_park_snapshots_anything_the_branch_does_not_hold() {
        let on = (Some("c1"), None);
        assert_eq!(plan(on, ("c1", "t1"), "t1"), Plan::Clean);
        assert_eq!(
            plan((Some("c1"), Some("s")), ("c1", "t1"), "t1"),
            Plan::Clear
        );
        assert_eq!(plan(on, ("c1", "t1"), "t2"), Plan::Snapshot, "uncommitted");
        assert_eq!(plan(on, ("c2", "t1"), "t1"), Plan::Snapshot, "unpushed");
        assert_eq!(plan((None, None), ("c1", "t1"), "t1"), Plan::Snapshot);
    }

    #[test]
    fn the_snapshot_push_overwrites_its_own_ref_alone_without_the_hooks() {
        let push = g().push(Some("abc"), "refs/pool-wip/t-1");
        assert_eq!(
            push.get(3..).unwrap_or_default(),
            [
                "git",
                "-C",
                "/session/cur/work",
                "-c",
                "core.hooksPath=/dev/null",
                "push",
                "--quiet",
                "origin",
                "+abc:refs/pool-wip/t-1"
            ]
        );
        assert_eq!(
            g().push(None, "refs/pool-wip/t-1")
                .last()
                .map(String::as_str),
            Some(":refs/pool-wip/t-1")
        );
    }

    #[test]
    fn the_listing_names_both_refs_and_reads_each_by_its_full_name() {
        let argv = g().list("https://github.com/o/r", "pool/t-1", "refs/pool-wip/t-1");
        assert_eq!(
            argv,
            [
                "env",
                "GIT_CONFIG_GLOBAL=/dev/null",
                "GIT_TERMINAL_PROMPT=0",
                "git",
                "ls-remote",
                "--",
                "https://github.com/o/r",
                "refs/heads/pool/t-1",
                "refs/pool-wip/t-1"
            ]
        );
        let out = "c1\trefs/heads/pool/t-1\ns1\trefs/pool-wip/t-1\nx\trefs/heads/x/pool/t-1\n";
        assert_eq!(listed(out, "refs/heads/pool/t-1").as_deref(), Some("c1"));
        assert_eq!(listed(out, "refs/pool-wip/t-1").as_deref(), Some("s1"));
        assert_eq!(listed("", "refs/pool-wip/t-1"), None);
        assert_eq!(
            Resume::of(Some("c1".into()), Some("s1".into())),
            Resume::Snapshot("s1".into())
        );
        assert_eq!(
            Resume::of(Some("c1".into()), None),
            Resume::Branch("c1".into())
        );
        assert_eq!(Resume::of(None, None), Resume::Rev);
    }
}
