"""open-webui state backup, the host twin of homelab-gitops apps/chat/backup.yaml.

usage: open-webui-backup counts DATA_DIR
       open-webui-backup backup DATA_DIR BACKUP_DIR

`counts` prints what `backup` compares: tables, chat and user rows, upload files. `backup` takes a consistent copy
with SQLite's online backup API (never a file copy of a live database), archives it with the uploads, restores the
archive into scratch and compares what comes back with what went in; only then does the archive get its final name.
"""
import glob
import os
import shutil
import sqlite3
import sys
import tarfile
import tempfile
import time

KEEP = 7


def read_back(path):
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    check = con.execute("PRAGMA integrity_check").fetchone()[0]
    if check != "ok":
        raise SystemExit(f"integrity_check on {path}: {check}")
    tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if not {"chat", "user"} <= tables:
        raise SystemExit(f"{path} has no chat or user table: not the open-webui database")
    counts = {t: con.execute(f'SELECT count(*) FROM "{t}"').fetchone()[0] for t in ("chat", "user")}
    con.close()
    return len(tables), counts


def upload_files(root):
    return sum(len(files) for _, _, files in os.walk(root))


def counts(data):
    tables, rows = read_back(f"{data}/webui.db")
    print(f"tables={tables} rows={rows} upload files={upload_files(f'{data}/uploads')}")


def backup(data, dest, scratch):
    for stale in glob.glob(f"{dest}/*.partial"):
        os.remove(stale)
    src = sqlite3.connect(f"file:{data}/webui.db?mode=ro", uri=True)
    copy = f"{scratch}/webui.db"
    dst = sqlite3.connect(copy)
    src.backup(dst)
    dst.close()
    src.close()
    before = read_back(copy)
    uploads = f"{data}/uploads"
    sent = upload_files(uploads)
    print("source: tables=%d rows=%s" % before, "upload files=%d" % sent)

    out = f"{dest}/open-webui-{time.strftime('%Y%m%d-%H%M%S')}.tar.gz"
    with tarfile.open(out + ".partial", "w:gz") as tar:
        tar.add(copy, arcname="webui.db")
        if os.path.isdir(uploads):
            tar.add(uploads, arcname="uploads")

    restore = f"{scratch}/restore"
    shutil.rmtree(restore, ignore_errors=True)
    with tarfile.open(out + ".partial") as tar:
        tar.extractall(restore, filter="data")
    after = read_back(f"{restore}/webui.db")
    got = upload_files(f"{restore}/uploads")
    if (after, got) != (before, sent):
        raise SystemExit(f"restore differs: {after} {got} files, expected {before} {sent} files")
    print("restored from archive: tables=%d rows=%s" % after, "upload files=%d" % got)

    os.rename(out + ".partial", out)
    print("done:", out, os.path.getsize(out), "bytes")
    dumps = sorted(glob.glob(f"{dest}/open-webui-*.tar.gz"), reverse=True)
    for old in dumps[KEEP:]:
        os.remove(old)
    print("retained:", *dumps[:KEEP], sep="\n")


if __name__ == "__main__":
    match sys.argv[1:]:
        case ["counts", data]:
            counts(data)
        case ["backup", data, dest]:
            with tempfile.TemporaryDirectory() as scratch:
                backup(data, dest, scratch)
        case _:
            raise SystemExit(__doc__)
