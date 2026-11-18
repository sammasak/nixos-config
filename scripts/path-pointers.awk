# Path pointers that resolve to no tracked file, for nix-comment-lint.sh. Input: `file:line:text` lines; the tracked
# paths (`git ls-files`) in `-v tracked=<file>`, the allowlist (`<file> <path>` lines, `#` comments) in
# `-v allowed=<file>`. A path resolves against the naming file's directory and each one above it, the repo root,
# modules/ (the docs' shorthand) and secrets/ (.sops.yaml's).
BEGIN {
  while ((getline f < tracked) > 0) {
    have[f] = 1
    while (sub(/\/[^\/]*$/, "", f)) have[f] = 1
  }
  close(tracked)
  while ((getline a < allowed) > 0) {
    sub(/[[:space:]]*#.*/, "", a)
    if (a != "") allow[a] = 1
  }
  close(allowed)
  ext = "(nix|sh|py|md|yaml|yml|json|toml|alloy|awk|fixture)"
  # ./x.nix and ../x.nix, or a/b.nix: a bare name without a slash is too often prose
  seg = "[A-Za-z0-9_][A-Za-z0-9_.@+-]*"
  re = "((\\.\\.?/)+" seg "(/" seg ")*|" seg "(/" seg ")+)\\." ext
}
function norm(p,    n, parts, i, out, k, s) {
  n = split(p, parts, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == "..") { if (k > 0) k--; continue }
    out[++k] = parts[i]
  }
  s = ""
  for (i = 1; i <= k; i++) s = s (i > 1 ? "/" : "") out[i]
  return s
}
function resolves(src, t,    d) {
  d = src
  while (sub(/\/[^\/]*$/, "", d)) if (norm(d "/" t) in have) return 1
  return (norm(t) in have) || (norm("modules/" t) in have) || (norm("secrets/" t) in have)
}
{
  file = $0; sub(/:.*/, "", file)
  rest = substr($0, length(file) + 2); line = rest; sub(/:.*/, "", line)
  text = substr(rest, length(line) + 2)
  seen = ""
  while (match(text, re)) {
    tok = substr(text, RSTART, RLENGTH)
    before = RSTART > 1 ? substr(text, RSTART - 1, 1) : ""
    pre = seen substr(text, 1, RSTART - 1)
    seen = pre tok
    after = substr(text, RSTART + RLENGTH, 1)
    text = substr(text, RSTART + RLENGTH)
    # part of a longer word or path (history.jsonl, $HOME/x, ~/x, .../x, a URL, a store path), a vault pointer, a hidden
    # directory (runtime state), or a quoted Nix attribute name (environment.etc."x/y", xdg.configFile's keys): not a
    # pointer into the repo
    if (before ~ /[A-Za-z0-9_.\/~$@:-]/ || after ~ /[A-Za-z0-9_]/) continue
    if (pre ~ /[Vv]ault:?[[:space:]]*`?$/) continue
    if (tok ~ /(^|\/)\.[A-Za-z]/) continue
    if (file ~ /\.nix$/ && before == "\"" && text ~ /^"[[:space:]]*(=|\.)/) continue
    if ((file " " tok) in allow) continue
    if (!resolves(file, tok)) print "path-pointer: " file ":" line ": " tok " resolves to no tracked file"
  }
}
