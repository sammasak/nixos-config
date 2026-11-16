# shellcheck shell=bash
# ollama-pull-pinned "TAG DIGEST"...: pull each tag not at its pin. Ollama cannot pull by digest, so a pull that
# yields another digest is removed again and the run exits 3: a failed pin leaves the tag absent, never wrong.
digest() { curl -fsS "http://$OLLAMA_HOST/api/tags" | jq -r --arg n "$1" '.models[] | select(.name == $n) | .digest'; }
status=0
for pin in "$@"; do
  name=${pin% *} want=${pin#* }
  [ "$(digest "$name")" = "$want" ] && continue
  ollama pull "$name"
  got=$(digest "$name")
  if [ "$got" != "$want" ]; then
    echo "$name: the registry served $got, pinned is $want; removed it" >&2
    ollama rm "$name"
    status=3
  fi
done
exit "$status"
