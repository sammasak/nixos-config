# Static readability metrics for Nix sources, emitted as one TSV row:
#
#   files <TAB> lines <TAB> nixLines <TAB> comments <TAB> maxFileLines <TAB> p50FileLines
#
# `lines` counts every physical line. `nixLines` counts only lines the scanner
# reaches in code state — it excludes the body of `''` and "..." strings. The
# comment ratio is reported over `nixLines`, not `lines`, so that moving an
# inline shell script out to a real .sh file (which deletes a large block of
# non-comment physical lines) cannot mechanically inflate the ratio and read as
# a regression.
#
# A "comment" is a line whose first non-blank character is '#' while the scanner
# is in code state. That is what separates real Nix commentary from CSS id
# selectors in a waybar style block and from shell comments inside an inline
# `script = ''...''`. Both look like `^\s*#` to grep; neither is Nix.
#
# The scanner tracks `''` indented strings (honouring the ''', ''$ and ''\
# escapes), "..." strings, and `${...}` antiquotation — including a `''` string
# opened inside an antiquotation inside another `''` string, which this tree
# does in modules/hardware/thermal.nix. State is a small explicit stack.
#
# Known limit: an identifier ending in two apostrophes (`x''`) would be read as
# a string delimiter. Nix allows such names; this tree has none. `--verify`
# reports any file that ends with a non-empty stack, which is how that class of
# mistake surfaces instead of silently skewing the metric.

function push(s) { stack[++sp] = s }
function pop() { if (sp > 0) sp-- }
function top() { return sp > 0 ? stack[sp] : "code" }

function scan(line,    i, n, c, c2, c3, state) {
  n = length(line)
  i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    c2 = substr(line, i, 2)
    state = top()

    if (state == "indented") {
      if (c2 == "''") {
        c3 = substr(line, i, 3)
        # ''' and ''\ are escapes. ''$ escapes a literal ${, so it is not an
        # antiquotation either.
        if (c3 == "'''" || c3 == "''\\" || c3 == "''$") { i += 3; continue }
        pop()
        i += 2
        continue
      }
      if (c2 == "${") { push("antiquote"); i += 2; continue }
      if (c == "\\") { i += 2; continue }
      i++
    } else if (state == "quoted") {
      if (c == "\\") { i += 2; continue }
      if (c2 == "${") { push("antiquote"); i += 2; continue }
      if (c == "\"") { pop() }
      i++
    } else {
      # code, or inside an antiquotation (which contains ordinary Nix)
      if (c2 == "''") { push("indented"); i += 2; continue }
      if (c == "\"") { push("quoted"); i++; continue }
      if (c == "{" && state == "antiquote") { push("brace"); i++; continue }
      if (c == "}" && (state == "antiquote" || state == "brace")) { pop(); i++; continue }
      # An unquoted '#' comments out the rest of the line.
      if (c == "#") return
      i++
    }
  }
}

function inCode() { return top() == "code" || top() == "antiquote" || top() == "brace" }

FNR == 1 {
  if (files > 0 && sp > 0 && verify) printf "unbalanced: %s\n", prevfile > "/dev/stderr"
  lines[++files] = 0
  sp = 0
}

{
  prevfile = FILENAME
  total++
  lines[files]++
  if (inCode()) {
    nixlines++
    if ($0 ~ /^[[:space:]]*#/) comments++
  }
  scan($0)
}

END {
  if (sp > 0 && verify) printf "unbalanced: %s\n", prevfile > "/dev/stderr"
  n = asort(lines)
  printf "%d\t%d\t%d\t%d\t%d\t%d\n", files, total, nixlines, comments, lines[n], lines[int((n + 1) / 2)]
}
