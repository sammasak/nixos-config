"""herman#76: the desktop data tests stop leaving herman-desktop-<pid>-<tag>.sqlite files (and their -wal, -shm and
-journal siblings) in the temp dir after a run. Run from the root of a herman tree."""
import pathlib
import re
import sys

text = pathlib.Path("apps/herman/src/data.rs").read_text()
tests = text[text.find("mod tests {"):]
problems = []
start = tests.find("fn temp_url(")
body = tests[start:tests.find("\n    }\n", start)] if start >= 0 else ""
if not body:
    problems.append("keep the helper fn temp_url in the tests module of apps/herman/src/data.rs")
guard = re.search(r"impl Drop for \w+ \{.*?remove_file", tests, re.S)
sweep = "read_dir" in body and "herman-desktop-" in body and "/proc/" in body
if not guard and not sweep:
    problems.append(
        "nothing removes the test databases: add a guard type with impl Drop that removes the file and its"
        " -wal/-shm/-journal siblings, or make temp_url sweep herman-desktop-<pid>-* files whose pid has no"
        " /proc/<pid> entry"
    )
if sweep and not re.search(r"process::id\(\)", body):
    problems.append("the sweep must skip files of the running process (std::process::id())")
print("\n".join(problems) or "ok")
sys.exit(bool(problems))
