//! A session's park and resume against a local bare remote, as the helper runs them in a slot: a dirty tree with
//! uncommitted, staged, deleted, untracked and unpushed work comes back identical in a fresh clone, ignored files
//! left behind, and a park that leaves nothing uncommitted removes the snapshot. `git` must be on PATH.

#![allow(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    reason = "the fixture's helpers: a failure there is the test failing"
)]

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use exec_pool::snapshot::{Git, Plan, Resume, listed, plan};

const BRANCH: &str = "pool/t-1";
const WIP: &str = "refs/pool-wip/t-1";

fn run(argv: &[String]) -> String {
    let out = Command::new(&argv[0]).args(&argv[1..]).output().unwrap();
    assert!(
        out.status.success(),
        "{argv:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap().trim_end().to_owned()
}

fn git(dir: &Path, args: &[&str]) -> String {
    let mut cmd = vec![
        "env".to_owned(),
        "GIT_CONFIG_GLOBAL=/dev/null".to_owned(),
        "GIT_CONFIG_NOSYSTEM=1".to_owned(),
        "git".to_owned(),
        "-C".to_owned(),
        dir.display().to_string(),
    ];
    cmd.extend(args.iter().map(|&a| a.to_owned()));
    run(&cmd)
}

fn write(path: &Path, bytes: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, bytes).unwrap();
}

/// Every file under `dir` but `.git`'s, with its bytes and whether it is executable.
fn files(dir: &Path) -> BTreeMap<PathBuf, (Vec<u8>, bool)> {
    fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<PathBuf, (Vec<u8>, bool)>) {
        for e in fs::read_dir(dir).unwrap() {
            let p = e.unwrap().path();
            let rel = p.strip_prefix(root).unwrap().to_owned();
            if rel == Path::new(".git") {
                continue;
            }
            if p.is_dir() {
                walk(root, &p, out);
            } else {
                let exec = fs::metadata(&p).unwrap().permissions().mode() & 0o100 != 0;
                out.insert(rel, (fs::read(&p).unwrap(), exec));
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(dir, dir, &mut out);
    out
}

/// The clone a turn makes: the remote's default branch, the agent's identity in its own config.
fn clone(remote: &str, into: &Path) {
    run(&[
        "env",
        "GIT_CONFIG_GLOBAL=/dev/null",
        "GIT_CONFIG_NOSYSTEM=1",
        "git",
        "clone",
        "--quiet",
        "-c",
        "user.name=pool",
        "-c",
        "user.email=pool@example.invalid",
        "--",
        remote,
        &into.display().to_string(),
    ]
    .map(str::to_owned));
}

/// The park as the helper runs it: what the remote holds, the plan, and the snapshot pushed or removed.
fn park(g: &Git<'_>, remote: &str, index: &Path) -> Plan {
    let heads = run(&g.head());
    let (head, head_tree) = heads.split_once('\n').unwrap();
    let remote_refs = run(&g.list(remote, BRANCH, WIP));
    let [read, add, write] = g.tree(&index.display().to_string());
    run(&read);
    run(&add);
    let tree = run(&write);
    let branch = listed(&remote_refs, &format!("refs/heads/{BRANCH}"));
    let wip = listed(&remote_refs, WIP);
    let p = plan(
        (branch.as_deref(), wip.as_deref()),
        (head, head_tree),
        &tree,
    );
    match p {
        Plan::Snapshot => {
            let commit = run(&g.commit(&tree, "pool: snapshot of t-1"));
            run(&g.push(Some(&commit), WIP));
        }
        Plan::Clear => {
            run(&g.push(None, WIP));
        }
        Plan::Clean => {}
    }
    let _ = fs::remove_file(index);
    p
}

/// The resume as a turn runs it in a fresh clone at `into`.
fn resume(remote: &str, into: &Path) -> Resume {
    clone(remote, into);
    let checkout = into.display().to_string();
    let g = Git {
        env: "env",
        git: "git",
        checkout: &checkout,
    };
    let remote_refs = run(&g.list(remote, BRANCH, WIP));
    let r = Resume::of(
        listed(&remote_refs, &format!("refs/heads/{BRANCH}")),
        listed(&remote_refs, WIP),
    );
    for (_, step) in r.steps(&g, (BRANCH, "main", WIP)) {
        run(&step);
    }
    r
}

#[test]
fn a_dirty_tree_comes_back_identical_in_a_fresh_clone_and_a_clean_park_drops_the_snapshot() {
    let root = std::env::temp_dir().join(format!("exec-pool-snapshot-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).unwrap();
    let bare = root.join("remote.git");
    let remote = bare.display().to_string();
    run(&["git", "init", "--quiet", "--bare", "-b", "main", &remote].map(str::to_owned));
    let seed = root.join("seed");
    clone(&remote, &seed);
    git(&seed, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    write(&seed.join(".gitignore"), "target/\n");
    write(&seed.join("src/lib.rs"), "fn a() {}\n");
    write(&seed.join("README.md"), "readme\n");
    // tracked although an ignore rule matches it
    write(&seed.join("target/keep"), "kept\n");
    git(&seed, &["add", "--all"]);
    git(&seed, &["add", "--force", "target/keep"]);
    git(&seed, &["commit", "--quiet", "-m", "seed"]);
    git(&seed, &["push", "--quiet", "origin", "main"]);

    // a first turn: the agent pushes its branch, then commits once more, leaves work uncommitted and stops
    let a = root.join("a");
    let resumed = resume(&remote, &a);
    assert_eq!(resumed, Resume::Rev);
    write(&a.join("src/lib.rs"), "fn a() {}\nfn pushed() {}\n");
    git(&a, &["commit", "--quiet", "-am", "pushed"]);
    git(&a, &["push", "--quiet", "origin", BRANCH]);
    write(
        &a.join("src/lib.rs"),
        "fn a() {}\nfn pushed() {}\nfn local() {}\n",
    );
    git(&a, &["commit", "--quiet", "-am", "committed, not pushed"]);
    write(&a.join("src/lib.rs"), "fn uncommitted() {}\n");
    fs::remove_file(a.join("README.md")).unwrap();
    write(&a.join("staged.txt"), "staged\n");
    git(&a, &["add", "staged.txt"]);
    write(&a.join("notes/todo.md"), "untracked\n");
    write(&a.join("bin/run"), "#!/bin/sh\n");
    fs::set_permissions(a.join("bin/run"), fs::Permissions::from_mode(0o755)).unwrap();
    write(&a.join("target/build.out"), "ignored build output\n");
    let checkout = a.display().to_string();
    let ga = Git {
        env: "env",
        git: "git",
        checkout: &checkout,
    };
    let index = root.join("snapshot.index");
    assert_eq!(park(&ga, &remote, &index), Plan::Snapshot);
    assert_eq!(
        git(&a, &["status", "--porcelain"]).lines().count(),
        5,
        "the park changes nothing in the checkout"
    );

    // the next turn, on another host: a fresh clone
    let b = root.join("b");
    let resumed = resume(&remote, &b);
    assert!(matches!(resumed, Resume::Snapshot(_)));
    let mut want = files(&a);
    want.remove(Path::new("target/build.out"));
    assert!(
        !b.join("target/build.out").exists(),
        "ignored: never pushed"
    );
    assert_eq!(files(&b), want);
    assert_eq!(
        git(&b, &["rev-parse", "HEAD"]),
        git(&a, &["rev-parse", "HEAD"]),
        "the unpushed commit is the branch's again"
    );
    assert_eq!(
        git(&b, &["rev-parse", "--abbrev-ref", "HEAD"]),
        BRANCH,
        "on its branch"
    );
    let status = git(&b, &["status", "--porcelain"]);
    assert!(
        status.contains(" D README.md") && status.contains("?? notes/"),
        "{status}"
    );
    assert!(
        git(&b, &["diff", "--cached"]).is_empty(),
        "uncommitted, none staged"
    );

    // the agent commits and pushes everything: its park removes the snapshot, and the turn after restores none
    let checkout = b.display().to_string();
    let gb = Git {
        env: "env",
        git: "git",
        checkout: &checkout,
    };
    git(&b, &["add", "--all"]);
    git(&b, &["commit", "--quiet", "-m", "all of it"]);
    git(&b, &["push", "--quiet", "origin", BRANCH]);
    assert_eq!(park(&gb, &remote, &index), Plan::Clear);
    assert_eq!(park(&gb, &remote, &index), Plan::Clean);
    let c = root.join("c");
    assert!(matches!(resume(&remote, &c), Resume::Branch(_)));
    assert_eq!(files(&c), files(&b));
    assert!(git(&c, &["status", "--porcelain"]).is_empty());
    fs::remove_dir_all(&root).unwrap();
}
