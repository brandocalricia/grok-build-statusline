# grok-build-statusline

**Problem:** Grok Build status line savings.

The built-in row (or a naive custom script) says **saved unpriced**. This command status line prints **exact routed tokens** and the **measured dollar gap versus grok-4.7** from `costUsdTicks / 1e10` (`saved_ticks / 10_000_000_000`). grok-4.6 matches grok-4.7 on that gap. grok-4.5 is cheaper only on cached input. `grok-4.7-build-fast` is 2x and is not a saving.

Example row:

```
project │ grok-4.7 │ 12% ctx │ 4.5×3 4.6×2 · saved 12,345 tok ($0.036199936)
```

GitHub Actions is off on purpose. Do not add workflows. Do not commit a live `ledger.json`.

## Install

`statusline.sh` is a Python 3 script (shebang `python3`). It uses `Path.home()`, not a hard-coded home directory.

```sh
cp statusline.sh ~/.grok/statusline.sh
chmod +x ~/.grok/statusline.sh
```

In `~/.grok/config.toml`:

```toml
[ui.status_line]
type = "command"
command = "~/.grok/statusline.sh"
```

Restart Grok. If you must use an absolute `command` path, replace YOURHOME yourself — do not commit a hard-coded home directory.

## How dollars are computed

1. Unique `subagent_spawned` events from every `updates.jsonl` under `~/.grok/sessions` (same child counted once).
2. For each grok-4.5 / grok-4.6 child with a `usage.json`, sum `totalTokens` and the tick gap versus pricing grok-4.7 on the same turns.
3. `format_usd(saved_ticks)` is integer ticks / 1e10, trailing zeros stripped, at least two decimal places.

Creating `~/.grok/auto-route/off` hides the counts without removing model pins.

## Test

```sh
python3 test_statusline.py
```

Asserts `format_usd(361999360) == "$0.036199936"`.

## License

MIT
