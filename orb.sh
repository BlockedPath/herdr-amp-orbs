#!/usr/bin/env bash
# Amp orbs in Herdr panes. Every action, pane and link handler in
# herdr-plugin.toml runs this script with a subcommand.
#
# An orb pane is the Amp TUI started as a Herdr `amp` agent, so Herdr's own
# agent detection drives the sidebar state and done notifications:
#   new orb      amp --executor orb             (orb boots on the first prompt)
#   attach       amp threads continue T-…        (wakes a sleeping orb on the next prompt)
#
# Written for macOS /bin/bash 3.2: no associative arrays, coproc or mapfile.
set -uo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
PLUGIN_ID="${HERDR_PLUGIN_ID:-blockedpath.amp-orbs}"
SELF="$(cd "$(dirname "$0")" && pwd)/orb.sh"

CTX="${HERDR_PLUGIN_CONTEXT_JSON:-}"
[ -n "$CTX" ] || CTX='{}'

# Defaults; override in $HERDR_PLUGIN_CONFIG_DIR/config.env.
ORB_PLACEMENT=split # split | tab
ORB_SPLIT=auto      # auto | right | down (split placement only)
ORB_NEW_ARGS=""     # extra amp args for new orbs, e.g. "--mode high"
if [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ] && [ -f "$HERDR_PLUGIN_CONFIG_DIR/config.env" ]; then
  # shellcheck disable=SC1091
  . "$HERDR_PLUGIN_CONFIG_DIR/config.env"
fi

THREAD_RE='T-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

notify() {
  "$HERDR" notification show "Amp orbs" --body "$1" >/dev/null 2>&1 || true
  echo "$1" >&2
}

die() {
  notify "$1"
  exit 1
}

find_bin() {
  local p
  if command -v "$1" 2>/dev/null; then return 0; fi
  for p in "$HOME/.local/bin/$1" "$HOME/.amp/bin/$1" "/opt/homebrew/bin/$1" "/usr/local/bin/$1"; do
    if [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

AMP="$(find_bin amp)" || die "amp CLI not found. Install it: curl -fsSL https://ampcode.com/install.sh | bash"

ctx() {
  jq -r --arg k "$1" '.[$k] // empty' <<<"$CTX"
}

# The directory new panes start in. It decides which Amp project an orb clones.
target_cwd() {
  local cwd
  cwd="$(ctx focused_pane_cwd)"
  [ -n "$cwd" ] || cwd="$(ctx workspace_cwd)"
  [ -n "$cwd" ] || cwd="$HOME"
  echo "$cwd"
}

target_pane() {
  local pane
  pane="$(ctx focused_pane_id)"
  [ -n "$pane" ] || pane="${HERDR_PANE_ID:-}"
  echo "$pane"
}

# Split wide panes to the right and tall or narrow ones down.
split_direction() {
  local pane=$1 w h
  if [ "$ORB_SPLIT" != auto ]; then
    echo "$ORB_SPLIT"
    return
  fi
  read -r w h < <("$HERDR" pane layout ${pane:+--pane "$pane"} 2>/dev/null | jq -r --arg p "$pane" '
    .result.layout.panes[]
    | select(.pane_id == $p or ($p == "" and .focused))
    | "\(.rect.width) \(.rect.height)"' | head -1)
  if [ -n "${w:-}" ] && [ -n "${h:-}" ] && [ "$w" -lt $((h * 5 / 2)) ]; then
    echo down
  else
    echo right
  fi
}

# Agent name for a thread: orb-<last 8 hex digits of its ID>.
agent_name() {
  printf 'orb-%s' "$(printf '%s' "$1" | tr -d '-' | tr 'A-F' 'a-f' | tail -c 8)"
}

# Opens a pane next to the focused one and starts `amp <args>` in it as a
# Herdr agent named $1, labelled $2.
open_amp_pane() {
  local name=$1 label=$2 cwd target res pane ws
  shift 2
  cwd="$(target_cwd)"
  target="$(target_pane)"

  if [ "$ORB_PLACEMENT" = tab ]; then
    ws="$(ctx workspace_id)"
    res="$("$HERDR" tab create ${ws:+--workspace "$ws"} --cwd "$cwd" --label "$label" --no-focus)" ||
      die "Could not create a tab for $label"
    pane="$(jq -r '.result.root_pane.pane_id' <<<"$res")"
  else
    res="$("$HERDR" pane split ${target:+--pane "$target"} --direction "$(split_direction "$target")" \
      --cwd "$cwd" --no-focus)" || die "Could not split a pane for $label"
    pane="$(jq -r '.result.pane.pane_id' <<<"$res")"
  fi

  "$HERDR" pane rename "$pane" "$label" >/dev/null 2>&1 || true
  if ! res="$("$HERDR" agent start "$name" --kind amp --pane "$pane" --timeout 45000 -- "$@" 2>&1)"; then
    "$HERDR" pane close "$pane" >/dev/null 2>&1 || true
    die "amp did not start in a pane: $res"
  fi
  "$HERDR" pane report-metadata "$pane" --source amp-orbs --token "orb=$label" >/dev/null 2>&1 || true
  "$HERDR" agent focus "$name" >/dev/null 2>&1 || true
}

cmd_new() {
  # ORB_NEW_ARGS is split into words on purpose.
  # shellcheck disable=SC2086
  open_amp_pane "orb-new-$(printf '%04x' "$RANDOM")" "new orb" --executor orb $ORB_NEW_ARGS
}

cmd_attach() {
  local id=$1 name meta executor title
  name="$(agent_name "$id")"
  # Already open in this session: jump to it instead of attaching twice.
  if "$HERDR" agent get "$name" >/dev/null 2>&1; then
    "$HERDR" agent focus "$name" >/dev/null 2>&1
    return
  fi
  # Orb threads have executorType "sandbox". Attaching the TUI to any other
  # thread makes this machine its executor, so its tools would run here.
  # The same export supplies the pane label: "<executor type> TAB <title>".
  meta="$("$AMP" threads export "$id" </dev/null 2>/dev/null |
    jq -r '(.meta.executorType // "") + "\t" + ((.title // "") | gsub("[\\t\\r\\n]+"; " "))')"
  executor="${meta%%$'\t'*}"
  title="${meta#*$'\t'}"
  [ "$executor" = sandbox ] ||
    die "$id is not an orb thread (executor: ${executor:-unknown}); not attaching"
  [ -n "$title" ] || title=$id
  open_amp_pane "$name" "$title" threads continue "$id"
}

# Link handler and selection action: attach to the thread in the clicked URL
# or the selected text.
cmd_open_thread() {
  local src id
  src="$(ctx clicked_url)"
  [ -n "$src" ] || src="$(ctx selected_text)"
  id="$(printf '%s' "$src" | grep -oE "$THREAD_RE" | head -1)"
  [ -n "$id" ] || die "No Amp thread ID in the clicked link or selection"
  cmd_attach "$id"
}

# First non-empty `amp top` snapshot, or nothing after 1.5 seconds.
# `amp top` never exits on its own, so it runs in the background and is killed.
# The deadline is a background sleep so the time jq takes per poll counts too.
top_snapshot() {
  local tmp pid timer line=""
  tmp="$(mktemp)" || return 0
  "$AMP" top --stream-jsonl </dev/null >"$tmp" 2>/dev/null &
  pid=$!
  sleep 1.5 &
  timer=$!
  while kill -0 "$timer" 2>/dev/null; do
    line="$(jq -c 'select((.threads | length) > 0)' "$tmp" 2>/dev/null | head -1)"
    [ -n "$line" ] && break
    sleep 0.1
  done
  kill "$pid" "$timer" 2>/dev/null
  wait "$pid" "$timer" 2>/dev/null
  rm -f "$tmp"
  echo "$line"
}

# Picker rows: <thread id> TAB <display text>. Scope "orbs" keeps threads whose
# checkout is the orb workspace path (/home/user/workspace/…) plus live threads
# the list did not return; "all" keeps every thread. The path is only a cheap
# filter: cmd_attach checks the real executor type before attaching.
cmd_list() {
  local scope=${1:-orbs} top threads agents list_tmp list_pid
  # Fetch the thread list while top_snapshot waits for live state.
  list_tmp="$(mktemp)" || return 1
  "$AMP" threads list --json --limit 60 </dev/null >"$list_tmp" 2>/dev/null &
  list_pid=$!
  top="$(top_snapshot)"
  [ -n "$top" ] || top='{"threads":[]}'
  if wait "$list_pid"; then threads="$(cat "$list_tmp")"; else threads='[]'; fi
  rm -f "$list_tmp"
  [ -n "$threads" ] || threads='[]'
  agents="$("$HERDR" agent list 2>/dev/null | jq -c '[.result.agents[]?.name // empty]' 2>/dev/null)" || agents='[]'
  [ -n "$agents" ] || agents='[]'

  jq -r -n --argjson top "$top" --argjson threads "$threads" --argjson agents "$agents" --arg scope "$scope" '
    def pad($n): tostring | if length > $n then .[:$n - 1] + "…" else . + (" " * ($n - length)) end;
    def age:
      (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t | (now - $t) as $s
      | if $s < 3600 then "\(($s / 60) | floor)m"
        elif $s < 86400 then "\(($s / 3600) | floor)h"
        else "\(($s / 86400) | floor)d" end;
    def orb_tree: (.tree // "") | test("^file:///home/user/workspace(/|$)");
    def agent_name: "orb-" + (.id | gsub("-"; "") | ascii_downcase | .[-8:]);

    ($top.threads // [] | map({(.id): .}) | add // {}) as $live
    | ($threads | map(.id)) as $ids
    | ($threads | map(. + ($live[.id] // {})))
      + [$top.threads[]? | select(.id as $i | $ids | index($i) | not)]
    | map(select($scope == "all" or (.tree == null) or orb_tree))
    | sort_by(.updated // .updatedAt // "") | reverse
    | .[]
    | agent_name as $name
    | [ .id,
        ((if .working then "●" else "○" end) + " "
         + ((.title // .id) | pad(40)) + "  "
         + ((.project // ((.tree // "") | split("/") | last) // "-") | pad(18)) + "  "
         + ((.updated // .updatedAt // "") | if . == "" then "" else age end | pad(4))
         + (if ($agents | index($name)) then "  ⧉ open" else "" end))
      ]
    | @tsv'
}

# The picker keeps its scope ("orbs" or "all") in $ORB_SCOPE_FILE, so ctrl-r
# reloads the list that is showing.
picker_scope() {
  local scope=""
  [ -n "${ORB_SCOPE_FILE:-}" ] && scope="$(cat "$ORB_SCOPE_FILE" 2>/dev/null)"
  echo "${scope:-orbs}"
}

# ctrl-a: switches the picker scope and prints the matching fzf prompt.
cmd_toggle_scope() {
  case "$(picker_scope)" in
    all) echo orbs >"$ORB_SCOPE_FILE" && echo 'orb> ' ;;
    *) echo all >"$ORB_SCOPE_FILE" && echo 'all> ' ;;
  esac
}

cmd_preview() {
  "$AMP" threads markdown "$1" </dev/null 2>&1 | tail -n 150
}

pause() {
  printf '\nPress any key to close.'
  read -rsn1 _ || true
}

# Applies an orb's working-tree changes once to the focused pane's checkout.
cmd_sync() {
  local id=$1 cwd ans
  cwd="$(target_cwd)"
  echo "Apply changes from $id"
  echo "into $cwd"
  echo
  if ! git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "That directory is not a Git checkout. Focus a pane in the right repo and try again."
    pause
    return 1
  fi
  echo "Current local changes:"
  git -C "$cwd" status --short | head -20
  echo
  printf 'Apply the orb changes now? [y/N] '
  read -r ans || ans=""
  case "$ans" in
    y | Y | yes)
      (cd "$cwd" && "$AMP" sync --apply "$id" --skip-checkout)
      ;;
    *) echo "Cancelled." ;;
  esac
  pause
}

cmd_open_picker() {
  "$HERDR" plugin pane open --plugin "$PLUGIN_ID" --entrypoint picker >/dev/null ||
    die "Could not open the orb picker"
}

cmd_picker() {
  local fzf opener=open
  fzf="$(find_bin fzf)" || {
    echo "The orb picker needs fzf (brew install fzf)."
    pause
    exit 1
  }
  command -v open >/dev/null 2>&1 || opener=xdg-open
  ORB_SCOPE_FILE="$(mktemp)" || exit 1
  export ORB_SCOPE_FILE
  trap 'rm -f "$ORB_SCOPE_FILE"' EXIT

  # ctrl-a runs transform-prompt first: it blocks until the scope file is
  # written, so the reload after it reads the new scope.
  FZF_DEFAULT_COMMAND="bash '$SELF' list" "$fzf" \
    --delimiter '\t' --with-nth 2 --no-sort --layout reverse \
    --prompt 'orb> ' \
    --header "enter attach · ctrl-n new orb · ctrl-s sync into $(target_cwd) · ctrl-o browser · ctrl-a orbs/all threads · ctrl-r refresh" \
    --preview "bash '$SELF' preview {1}" \
    --preview-window 'right,40%,wrap,follow' \
    --bind "enter:become(bash '$SELF' attach {1})" \
    --bind "ctrl-n:become(bash '$SELF' new)" \
    --bind "ctrl-s:become(bash '$SELF' sync {1})" \
    --bind "ctrl-o:execute-silent($opener https://ampcode.com/threads/{1})" \
    --bind "ctrl-a:transform-prompt(bash '$SELF' toggle-scope)+reload(bash '$SELF' list)" \
    --bind "ctrl-r:reload(bash '$SELF' list)"
}

case "${1:-}" in
  new) cmd_new ;;
  attach) cmd_attach "${2:?thread id}" ;;
  open-thread) cmd_open_thread ;;
  open-picker) cmd_open_picker ;;
  picker) cmd_picker ;;
  list) cmd_list "${2:-$(picker_scope)}" ;;
  toggle-scope) cmd_toggle_scope ;;
  preview) cmd_preview "${2:?thread id}" ;;
  sync) cmd_sync "${2:?thread id}" ;;
  *)
    echo "usage: orb.sh new | attach <T-…> | open-thread | open-picker | picker | list [orbs|all] | toggle-scope | preview <T-…> | sync <T-…>" >&2
    exit 2
    ;;
esac
