//! A session tree's attach and detach on a temp dir, as the root helper does them around each turn: the tree comes
//! back at the same dock path with its uncommitted work and the agent's transcript as they were.

#![allow(
    clippy::unwrap_used,
    reason = "the fixture's helpers: a failure there is the test failing"
)]

use std::fs;
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::path::Path;

use exec_pool::sync::{self, Depot};
use exec_pool::workspace::{Error, Sessions};

fn write(path: &Path, bytes: &[u8]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, bytes).unwrap();
}

#[test]
fn a_tree_attaches_to_a_slots_dock_and_comes_back_intact_at_the_same_path() {
    let root = std::env::temp_dir().join(format!("exec-pool-sessions-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    for slot in ["pool1", "pool2"] {
        fs::create_dir_all(root.join("dock").join(slot)).unwrap();
    }
    let me = fs::metadata(std::env::temp_dir()).unwrap();
    let (uid, gid) = (me.uid(), me.gid());
    let s = Sessions::new(root.clone());
    let tree = s.tree("t-1");
    assert_eq!(tree, root.join("742d31/tree"));
    assert!(matches!(
        s.attach("t-1", "pool1", uid),
        Err(Error::NoTree(_))
    ));
    s.create("t-1", (uid, gid)).unwrap();
    // the guest user may enter the tree's root but not change it: only home and work are its own
    let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o7777;
    assert_eq!(mode(&tree), 0o711);
    assert_eq!(mode(&tree.join("home")), 0o700);
    s.attach("t-1", "pool1", uid).unwrap();
    let docked = s.docked("pool1");
    assert_eq!(docked, root.join("dock/pool1/cur"));
    assert!(s.dock_busy("pool1") && !tree.exists());
    // the turn: the agent's transcript and an uncommitted change, at the paths the guest sees under /session/cur
    let transcript = b"{\"type\":\"user\",\"message\":\"nonce 4711\"}\n";
    write(
        &docked.join("home/.claude/projects/-session-cur-work/u.jsonl"),
        transcript,
    );
    write(&docked.join("work/src/lib.rs"), b"fn uncommitted() {}\n");
    // another tree cannot attach over it, and the task's own cannot attach twice
    s.create("t-2", (uid, gid)).unwrap();
    assert!(matches!(
        s.attach("t-2", "pool1", uid),
        Err(Error::DockBusy(_))
    ));
    assert!(matches!(
        s.attach("t-1", "pool2", uid),
        Err(Error::NoTree(_))
    ));
    s.detach("t-1", "pool1").unwrap();
    assert!(!s.dock_busy("pool1"));
    assert!(matches!(s.detach("t-1", "pool1"), Err(Error::NoTree(_))));
    // the next turn on another slot finds it at the same guest path
    s.attach("t-1", "pool2", uid).unwrap();
    let again = s.docked("pool2");
    assert_eq!(
        fs::read(again.join("home/.claude/projects/-session-cur-work/u.jsonl")).unwrap(),
        transcript
    );
    assert_eq!(
        fs::read(again.join("work/src/lib.rs")).unwrap(),
        b"fn uncommitted() {}\n"
    );
    // a tree whose owner is not the slot home's does not attach
    assert!(matches!(
        s.attach("t-2", "pool1", uid.wrapping_add(1)),
        Err(Error::Owner { .. })
    ));
    s.detach("t-1", "pool2").unwrap();
    fs::remove_dir_all(&root).unwrap();
}

#[test]
fn an_unprepared_tree_is_made_afresh_and_a_prepared_one_is_kept() {
    let root = std::env::temp_dir().join(format!("exec-pool-prepared-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let me = fs::metadata(std::env::temp_dir()).unwrap();
    let owner = (me.uid(), me.gid());
    let s = Sessions::new(root.clone());
    s.create("t-1", owner).unwrap();
    // a first turn whose clone failed half-way, before the mark
    write(&s.tree("t-1").join("work/partial"), b"x");
    s.create("t-1", owner).unwrap();
    assert!(!s.tree("t-1").join("work/partial").exists());
    fs::write(s.prepared("t-1"), "").unwrap();
    assert!(matches!(s.create("t-1", owner), Err(Error::TreeExists(_))));
    fs::remove_dir_all(&root).unwrap();
}

/// Whether rsync can keep a mode in a user xattr under `root`, as the store does: the hosts' ext4 can, a build sandbox's
/// tmpfs may not, and then the test says so and skips.
fn xattrs(rsync: &str, root: &Path) -> bool {
    fs::write(root.join("probe"), b"").unwrap();
    // read-only, so the copy has to record its mode
    fs::set_permissions(root.join("probe"), fs::Permissions::from_mode(0o444)).unwrap();
    let probe = std::process::Command::new(rsync)
        .args(["-a", "-M--fake-super"])
        .arg(root.join("probe"))
        .arg(root.join("probed"))
        .output()
        .unwrap();
    if !probe.status.success() {
        eprintln!(
            "skipped: no user xattrs under {}: {}",
            root.display(),
            String::from_utf8_lossy(&probe.stderr)
        );
        let _ = fs::remove_dir_all(root);
    }
    probe.status.success()
}

/// A session tree as a turn leaves it on acer: a transcript, uncommitted work, a hard link, a Home Manager link (it
/// dangles on the other host until the next attach relinks it), a key the agent copied in, a gh and a Claude login, a
/// read-only git object.
fn parked(acer: &Sessions, (uid, gid): (u32, u32)) -> std::path::PathBuf {
    acer.create("t-1", (uid, gid)).unwrap();
    let tree = acer.tree("t-1");
    write(&tree.join("home/.claude/projects/w/u.jsonl"), b"transcript");
    write(&tree.join("work/repo/dirty.txt"), b"uncommitted");
    write(&tree.join("home/.ssh/id_ed25519"), b"a key");
    write(&tree.join("home/.config/gh/hosts.yml"), b"a login");
    write(&tree.join("home/.claude/.credentials.json"), b"a login");
    write(&tree.join("work/repo/.git/objects/ab/cd"), b"object");
    fs::hard_link(
        tree.join("work/repo/dirty.txt"),
        tree.join("work/repo/twin"),
    )
    .unwrap();
    std::os::unix::fs::symlink("/nix/store/x-home-files/.bashrc", tree.join("home/.bashrc"))
        .unwrap();
    let set = |p: &Path, m: u32| fs::set_permissions(p, fs::Permissions::from_mode(m)).unwrap();
    set(&tree.join("work/repo/.git/objects/ab/cd"), 0o444);
    set(&tree.join("work/repo/.git/objects/ab"), 0o555);
    tree
}

#[test]
fn a_parked_tree_goes_to_the_store_and_comes_back_on_another_host_as_it_was() {
    let root = std::env::temp_dir().join(format!("exec-pool-store-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let (acer, msi) = (
        Sessions::new(root.join("acer")),
        Sessions::new(root.join("msi")),
    );
    let me = fs::metadata(std::env::temp_dir()).unwrap();
    let (uid, gid) = (me.uid(), me.gid());
    let stored = root.join("store");
    fs::create_dir_all(&stored).unwrap();
    // acer's own store, and msi's way to it: here a shell standing in for ssh and the forced command's cd
    let local = Depot::Local {
        root: stored.clone(),
        owner: format!("{uid}:{gid}"),
    };
    let remote = Depot::Remote {
        dest: "acer".to_owned(),
        ssh: format!(
            "bash -c 'cd {} && shift && exec \"$@\"' ssh",
            stored.display()
        ),
    };
    let rsync = std::env::var("EXEC_POOL_TEST_RSYNC").unwrap_or_else(|_| "rsync".to_owned());
    if !xattrs(&rsync, &root) {
        return;
    }
    let hex = Sessions::hex("t-1");
    let tree = parked(&acer, (uid, gid));
    let mode = |p: &Path| fs::symlink_metadata(p).unwrap().permissions().mode() & 0o7777;
    let set = |p: &Path, m: u32| fs::set_permissions(p, fs::Permissions::from_mode(m)).unwrap();
    let dir = acer.dir("t-1");
    fs::write(dir.join(sync::GENERATION), "5").unwrap();

    // parked on acer, into its own store
    sync::push((&rsync, "chown"), &local, (&dir, &hex), 5).unwrap();
    assert_eq!(sync::generation(&stored.join(&hex)), Some(5));

    // woken on msi
    let theirs = msi.dir("t-1");
    assert!(
        sync::pull(&rsync, &remote, (&theirs, &hex), 6, (uid, gid)).is_err(),
        "the store holds 5"
    );
    assert!(!msi.tree("t-1").exists() && !theirs.join("incoming").exists());
    assert_eq!(
        sync::pull(&rsync, &remote, (&theirs, &hex), 5, (uid, gid)),
        Ok(5)
    );
    let got = msi.tree("t-1");
    assert_eq!(sync::generation(&theirs), Some(5));
    assert_eq!(
        fs::read(got.join("home/.claude/projects/w/u.jsonl")).unwrap(),
        b"transcript"
    );
    assert_eq!(
        fs::read(got.join("work/repo/dirty.txt")).unwrap(),
        b"uncommitted"
    );
    assert_eq!(fs::metadata(got.join("work/repo/twin")).unwrap().nlink(), 2);
    assert_eq!(
        fs::read_link(got.join("home/.bashrc")).unwrap(),
        Path::new("/nix/store/x-home-files/.bashrc")
    );
    assert_eq!(mode(&got), 0o711);
    assert_eq!(mode(&got.join("home")), 0o700);
    assert_eq!(mode(&got.join("work/repo/.git/objects/ab/cd")), 0o444);
    assert_eq!(mode(&got.join("work/repo/.git/objects/ab")), 0o555);
    assert_eq!(fs::metadata(got.join("work")).unwrap().uid(), uid);
    assert!(
        !got.join("home/.ssh").exists()
            && !got.join("home/.config/gh/hosts.yml").exists()
            && !got.join("home/.claude/.credentials.json").exists(),
        "a key or a login never leaves its host"
    );

    // parked on msi at a later turn: its tree replaces the store's copy, nothing of the old one left behind, a file
    // in a read-only directory included
    fs::remove_file(got.join("work/repo/twin")).unwrap();
    set(&got.join("work/repo/.git/objects/ab"), 0o755);
    fs::remove_file(got.join("work/repo/.git/objects/ab/cd")).unwrap();
    set(&got.join("work/repo/.git/objects/ab"), 0o555);
    fs::write(theirs.join(sync::GENERATION), "7").unwrap();
    sync::push((&rsync, "chown"), &remote, (&theirs, &hex), 7).unwrap();
    assert_eq!(sync::generation(&stored.join(&hex)), Some(7));
    assert!(!stored.join(&hex).join("tree/work/repo/twin").exists());
    assert!(
        !stored
            .join(&hex)
            .join("tree/work/repo/.git/objects/ab/cd")
            .exists()
    );

    // acer's run at 6 lost its lease to msi's at 7: it does not put its older tree back
    fs::write(dir.join(sync::GENERATION), "6").unwrap();
    assert!(sync::push((&rsync, "chown"), &local, (&dir, &hex), 6).is_err());
    assert_eq!(sync::generation(&stored.join(&hex)), Some(7));

    for d in [&tree, &got] {
        set(&d.join("work/repo/.git/objects/ab"), 0o755);
    }
    let _ = fs::remove_dir_all(&root);
}
