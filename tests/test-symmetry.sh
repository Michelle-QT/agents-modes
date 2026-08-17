#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_cmd jq
require_cmd python3

note "checking generated target conformance cell by cell"
matrix="$(tmp_dir conformance)/matrix.json"
python3 "$ROOT/tools/agents-modes-gen" conformance-matrix-json --output "$matrix"
jq empty "$matrix" || fail "conformance matrix is not valid JSON"
jq -e --slurpfile spec "$ROOT/modes.json" '
  $spec[0] as $s
  | all(.[];
      . as $row
      | if .status == "conformant" then
          (any($s.gaps[]?; .axis == $row.axis and (.targets | index($row.target)) and (.modes | index($row.mode))) | not)
          and (any($s.targets[$row.target].gaps[]?; .axis == $row.axis and (.modes | index($row.mode))) | not)
        elif .status == "accepted-gap" then
          any($s.gaps[]?; .axis == $row.axis and (.targets | index($row.target)) and (.modes | index($row.mode)))
        elif .status == "target-gap" then
          any($s.targets[$row.target].gaps[]?; .axis == $row.axis and (.modes | index($row.mode)))
        else
          false
        end)
' "$matrix" >/dev/null || fail "conformance status does not resolve to exactly its declared gap class"

while IFS=$'\t' read -r mode axis claude_status codex_status; do
  [ -n "$mode" ] || continue
  if [ "$claude_status" != "$codex_status" ]; then
    jq -e \
      --arg mode "$mode" \
      --arg axis "$axis" \
      --arg claude "$claude_status" \
      --arg codex "$codex_status" '
        any(.gaps[]?;
          .axis == $axis and (.modes | index($mode))
          and (((.targets | index("claude")) and $claude == "accepted-gap")
               or ((.targets | index("codex")) and $codex == "accepted-gap")))
        or any(.targets.claude.gaps[]?;
          .axis == $axis and (.modes | index($mode)) and $claude == "target-gap")
        or any(.targets.codex.gaps[]?;
          .axis == $axis and (.modes | index($mode)) and $codex == "target-gap")
      ' "$ROOT/modes.json" >/dev/null \
        || fail "$mode/$axis differs without an explicit gap: Claude=$claude_status Codex=$codex_status"
  fi
done < <(
  jq -r '
    group_by([.mode, .axis])[]
    | (map(select(.target == "claude"))[0]) as $c
    | (map(select(.target == "codex"))[0]) as $x
    | [$c.mode, $c.axis, $c.status, $x.status] | @tsv
  ' "$matrix"
)

note "checking target-effective prompts preserve the shared helper vocabulary"
prompt_dir="$(tmp_dir generated-prompts)"
for target in claude codex; do
  while IFS= read -r mode; do
    python3 "$ROOT/tools/agents-modes-gen" prompt "$target" "$mode" > "$prompt_dir/$target-$mode.prompt.md"
  done < <(jq -r '.modes | to_entries[] | select(.value.commands.grants | index("sandbox-escape")) | .key' "$ROOT/modes.json")
done
for prompt in "$prompt_dir"/*.prompt.md; do
  assert_not_contains "$prompt" 'codex/bin/sandbox-escape'
  assert_not_contains "$prompt" 'Codex project escape'
  assert_not_contains "$prompt" 'Claude invokes'
  assert_not_contains "$prompt" 'Codex invokes'
  assert_not_contains "$prompt" 'Invoke as `./sandbox-escapes/<name>'
  assert_not_contains "$prompt" 'Invoke by path'
  assert_contains "$prompt" 'sandbox-escape <name> ...'
done

assert_contains "$ROOT/codex/helpers/codex-launcher-dispatch.sh" 'codex_start_helper_dispatch'
assert_not_contains "$ROOT/Makefile" 'prefix_rule(pattern=["runbox"], decision="allow")'
assert_not_contains "$ROOT/Makefile" 'prefix_rule(pattern=["sandbox-escape"], decision="allow")'
assert_contains "$ROOT/README.md" '`sandbox-escape <name>`'

printf 'ok - target conformance differs only at explicit gaps\n'
