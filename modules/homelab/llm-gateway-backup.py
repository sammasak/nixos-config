"""llm-gateway state backup, the host twin of homelab-gitops apps/llm-gateway/backup.yaml.

usage: llm-gateway-backup counts STATE_DB
       llm-gateway-backup backup STATE_DB BACKUP_DIR

`counts` prints what `backup` compares: the rows of every table. `backup` takes a consistent copy with SQLite's
online backup API (never a file copy of a live database), inside the read transaction the source counts come from,
restores the copy into scratch with the same API and compares the restored counts with the source's; only then does
the dump get its final name.
"""
import glob
import os
import sqlite3
import sys
import tempfile
import time

KEEP = 7


def table_counts(con, what):
    check = con.execute("PRAGMA integrity_check").fetchone()[0]
    if check != "ok":
        raise SystemExit(f"integrity_check on {what}: {check}")
    tables = sorted(r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'"))
    if not {"ledger", "signatures"} <= set(tables):
        raise SystemExit(f"{what} has no ledger or signatures table: not the llm-gateway database")
    return {t: con.execute(f'SELECT count(*) FROM "{t}"').fetchone()[0] for t in tables}


def read_back(path):
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    counts = table_counts(con, path)
    con.close()
    return counts


def backup(db, dest, scratch):
    for stale in glob.glob(f"{dest}/*.partial"):
        os.remove(stale)
    out = f"{dest}/llm-gateway-{time.strftime('%Y%m%d-%H%M%S')}.sqlite3"
    # one read transaction: the counts and the copy see the same snapshot while the gateway keeps writing
    src = sqlite3.connect(f"file:{db}?mode=ro", uri=True, isolation_level=None)
    src.execute("BEGIN")
    before = table_counts(src, db)
    dst = sqlite3.connect(out + ".partial")
    src.backup(dst)
    # a WAL copy would leave -wal and -shm files beside each dump, which pruning never removes
    dst.execute("PRAGMA journal_mode=DELETE")
    dst.close()
    src.execute("COMMIT")
    src.close()
    print("source:", before)

    restore = f"{scratch}/restore.sqlite3"
    dump = sqlite3.connect(f"file:{out}.partial?mode=ro", uri=True)
    back = sqlite3.connect(restore)
    dump.backup(back)
    back.close()
    dump.close()
    after = read_back(restore)
    if after != before:
        raise SystemExit(f"restore differs: {after}, expected {before}")
    print("restored:", after)

    os.rename(out + ".partial", out)
    print("done:", out, os.path.getsize(out), "bytes")
    dumps = sorted(glob.glob(f"{dest}/llm-gateway-*.sqlite3"), reverse=True)
    for old in dumps[KEEP:]:
        os.remove(old)
    print("retained:", *dumps[:KEEP], sep="\n")


def main(argv):
    if len(argv) == 3 and argv[1] == "counts":
        print(read_back(argv[2]))
    elif len(argv) == 4 and argv[1] == "backup":
        with tempfile.TemporaryDirectory() as scratch:
            backup(argv[2], argv[3], scratch)
    else:
        raise SystemExit(__doc__)


main(sys.argv)
