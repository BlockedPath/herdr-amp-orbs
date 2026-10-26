# Amp Orbs for Herdr

A Herdr plugin that runs [Amp orbs](https://ampcode.com/docs/orbs) in Herdr panes. An orb is a remote machine where Amp's agent works on one thread.

Each orb pane runs the Amp TUI as a Herdr `amp` agent. Herdr's own agent detection then shows the orb in the sidebar as idle, working, or done, and sends its normal done notifications.

## What it adds

| Herdr entry | What it does |
|---|---|
| Action **New Amp orb** | Splits a pane next to the focused one and starts `amp --executor orb` in that pane's directory. Amp uses the directory's Git remotes to pick the project. The orb boots when you submit the first prompt. |
| Action **Amp orbs: attach, sync, browse** | Opens a popup listing your orb threads, with a live preview of each one. |
| Ctrl-click on an `https://ampcode.com/threads/T-…` link | Opens that thread in a pane. |
| Action **Open Amp thread (clicked or selected) in a pane** | Same as the Ctrl-click, using the selected text. |

Keys in the orb popup:

| Key | Action |
|---|---|
| `enter` | Attach to the thread in a new pane, or jump to its pane if it is already open (`⧉`) |
| `ctrl-n` | New orb |
| `ctrl-s` | Apply the orb's working-tree changes once to the focused pane's checkout (`amp sync --apply`). It shows `git status` and asks before writing. |
| `ctrl-o` | Open the thread on ampcode.com |
| `ctrl-a` | Switch between orb threads (`orb>`) and all threads (`all>`) |
| `ctrl-r` | Refresh, keeping the current list |

`●` means the agent is working and `○` means idle. `⧉` after it means the thread is already open in a pane.

## Requirements

- Herdr 0.9.3 or later
- `amp`, signed in (`amp login`). Starting or resuming an orb needs Amp Megawatt/Gigawatt or at least $2 in credits.
- `jq`
- `fzf`, for the popup

## Install

```bash
herdr plugin install BlockedPath/herdr-amp-orbs
```

To work on the plugin from a local clone instead, link the clone:

```bash
herdr plugin link /path/to/herdr-amp-orbs
```

Bind keys in `~/.config/herdr/config.toml`, then run `herdr server reload-config`:

```toml
[[keys.command]]
key = "prefix+shift+o"
type = "plugin_action"
command = "blockedpath.amp-orbs.pick"
description = "amp orbs"

[[keys.command]]
key = "prefix+a"
type = "plugin_action"
command = "blockedpath.amp-orbs.new"
description = "new amp orb"
```

To remove the plugin, run `herdr plugin unlink blockedpath.amp-orbs`.

## Configuration

Optional. Create `config.env` in the directory printed by `herdr plugin config-dir blockedpath.amp-orbs`:

```bash
ORB_PLACEMENT=split    # split (default) or tab
ORB_SPLIT=auto         # auto (default), right or down
ORB_NEW_ARGS="--mode high"   # extra amp arguments for new orbs
```

## How it works

- **New orb** runs `herdr agent start orb-new-XXXX --kind amp --pane <new pane> -- --executor orb`.
- **Attach** first checks that the thread's executor type is `sandbox`, which is how Amp marks orb threads. Then it runs `amp threads continue T-…` as agent `orb-<last 8 hex digits of the thread ID>`. It refuses any other thread, because attaching the TUI to a thread that ran on another machine makes this machine its executor.
- The popup lists threads from `amp threads list` and adds live state from `amp top`. Orb threads are identified by their `/home/user/workspace` checkout path.

Attaching was tested on a live orb. The TUI joins as a client and the orb stays the executor: a prompt sent from the Herdr pane ran on the orb (`hostname` returned `e2b.local`, `pwd` returned `/home/user/workspace`), and Herdr showed the agent going from working to idle.

## Known limits

- A new orb's pane is named `orb-new-XXXX` for its whole life. The thread ID is not known until the first prompt, so the popup does not mark it `⧉`.
