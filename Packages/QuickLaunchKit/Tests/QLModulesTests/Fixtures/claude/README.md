Recorded from real `claude -p --output-format stream-json --verbose --include-partial-messages`
runs with Claude Code 2.1.304 (local paths replaced with /tmp/fixture; the `system/init` event trimmed to a few keys).
Re-record when the CLI's format changes. Prompts:

- `text.jsonl`: "Reply with exactly: pong"
- `tool.jsonl`: "Read note.txt and tell me its contents in one line." (allowed tool use)
- `denied.jsonl`: "Create a file named out.txt …" with Write not allowed (`--permission-mode dontAsk`)
- `error.jsonl`: `--resume` with a session id that doesn't exist (exit status 1)
