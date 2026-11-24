//! A session tree's attach and detach on a temp dir, as the root helper does them around each turn: the tree comes
//! back at the same dock path with its uncommitted work and the agent's transcript as they were.

#![allow(
    clippy::unwrap_used,
    reason = "the fixture's helpers: a failure there is the test failing"
)]

use std::fs;
use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

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
