# 0009. Selection capture and paste-back; Claude skills through the generic panel

Status: Accepted
Date: 2026-10-20

## Context
M5 brings Claude Code skills: run a skill on the selected text (or typed text) and see the result. This needs the two text endpoints that decision 0003 reserved for core, `input: selection` and `output: replace_selection`, as well as a way to stop a run from the panel. It also has to settle what a Claude run looks like in the UI. Skills live in several places: the user folder, project folders, plugins, skills synced from claude.ai, and skills bundled into the CLI. The CLI has no command that lists them without running a model turn.

## Decision
- **`SelectionService` is a core service protocol**, implemented in QLPlatform by `SystemSelection`, and the executor uses it for every text-capable action:
  - **Reading:** first the Accessibility API (the selected text of the app's focused element), then a synthetic ⌘C if that gives nothing (Electron apps, many terminals). The ⌘C path saves and restores the whole pasteboard. If both come up empty, the run falls back to `input: prompt`, so the user can type the text instead.
  - **Replacing:** paste with a synthetic ⌘V and restore the pasteboard afterwards. The temporary clipboard content is marked transient, so clipboard managers skip it. If a different app is in front by the time output arrives, nothing is pasted and the run fails with a message.
- **Launcher runs that read the selection hide the launcher first**, so the app the user came from has keyboard focus for the ⌘C fallback. A panel run then shows the launcher again.
- **The panel can stop the run it shows.** `OutputPanelPresenting.beginOutput` gets a `cancel` closure. The executor runs each request in a task it owns and cancels that task.
  - Esc on a running output stops the run, which terminates the process, with SIGKILL after a 2 s grace period.
  - Clicking elsewhere only hides the panel. The run continues, and the launcher hotkey brings the output back while it's running or finished but not yet seen.
- **Claude runs use the generic output panel and stream only text.** The user decided this: there are no tool chips and no Claude-specific view for now. Follow-up questions in the same session are deferred too. They'd need the panel to accept a reply, which is a generic extension and would get its own decision. The skill runs `claude -p … --output-format stream-json --include-partial-messages`, and the module parses the NDJSON. Unknown events are ignored.
  - **Errors:** an error result fails the run. Permission denials also fail it, with a hint to add the tool to `claude.allowed_tools`, because output written after a denial is usually Claude explaining what it couldn't do, which shouldn't be pasted into a document.
- **Skills are discovered from the filesystem.** The sources are:
  - `~/.claude/skills/*/SKILL.md`
  - `<default_cwd>/.claude/skills/*/SKILL.md`
  - the skills of user-scope plugins that are enabled in `~/.claude/settings.json`, invoked as `/<plugin>:<skill>`

  Each skill becomes a `claude/<skill>` command. Skills synced from claude.ai and skills bundled with the CLI are left out: the former use an undocumented internal format, and the latter aren't on disk. Both still run when named explicitly with `claude.skill`.
- **Frontmatter is parsed by an injected YAML parser** that produces a core `ConfigValue`, so Yams stays confined to QLConfigYAML.
- **`ExecutableNotFound` is a typed core error** thrown by `ProcessRunning`, so a module can add a fix hint, e.g. "install Claude Code or set claude.binary". The binary is `claude.binary` if set, otherwise `claude` on the login `PATH`. The captured login environment, or its fallback that adds `~/.local/bin` and `/opt/homebrew/bin`, makes a separate locator unnecessary.

## Consequences
- `system.shell` and every future text action gain selection input and in-place replacement for free.
- The ⌘C fallback can briefly put the selection on the clipboard, and it reads nothing if the app ignores ⌘C. In some editors, ⌘C with nothing selected copies the whole line.
- Paste-back restores the clipboard after a fixed delay (400 ms). An app that is very slow to handle ⌘V could paste the restored content instead.
- A long Claude run shows only "Waiting for output…" while tools run; the log has the details.
- Skills that exist only in the synced or bundled sets don't appear in the launcher.
