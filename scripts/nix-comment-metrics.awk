# Static readability metrics for Nix sources, emitted as one TSV row:
#
#   files <TAB> lines <TAB> comments <TAB> maxFileLines <TAB> p50FileLines
#
# A "comment" is a line whose first non-blank character is '#' while the scanner
# is outside any string. That second condition is what separates real Nix
# commentary from CSS id selectors in a waybar style block and from shell
# comments inside an inline `script = ''...''`. Both look like `^\s*#` to grep
# and neither is Nix.
#
# The scanner is a small state machine, not a parser: it tracks `''` indented
# strings (honouring the ''', ''$ and ''\ escapes) and "..." strings. It does
# not descend into `${...}` antiquotation, so a comment written inside an
# interpolation is missed. That has never occurred in this tree.

function scan(line,    i, n, c, c2, c3) {
  n = length(line)
  i = 1
  while (i <= n) {
    c = substr(line, i, 1)
    c2 = substr(line, i, 2)

    if (in_indented) {
      if (c2 == "''") {
        c3 = substr(line, i, 3)
        # ''' , ''$ and ''\ are escapes: they do not close the string.
        if (c3 == "'''" || c3 == "''$" || c3 == "''\\") { i += 3; continue }
        in_indented = 0
        i += 2
        continue
      }
      i++
    } else if (in_quoted) {
      if (c == "\\") { i += 2; continue }
      if (c == "\"") { in_quoted = 0 }
      i++
    } else {
      if (c2 == "''") { in_indented = 1; i += 2; continue }
      if (c == "\"") { in_quoted = 1; i++; continue }
      # An unquoted '#' comments out the rest of the line.
      if (c == "#") return
      i++
    }
  }
}

FNR == 1 {
  lines[++files] = 0
  in_indented = 0
  in_quoted = 0
}

{
  total++
  lines[files]++
  if (!in_indented && !in_quoted && $0 ~ /^[[:space:]]*#/) comments++
  scan($0)
}

END {
  n = asort(lines)
  printf "%d\t%d\t%d\t%d\t%d\n", files, total, comments, lines[n], lines[int((n + 1) / 2)]
}
