# 0026. Module-declared settings; Claude projects, sessions and terminals

Status: Accepted
Date: 2026-10-22

## Context
The user has two uses for Claude Code:
- quick one-offs, often a skill, where skills are usually per project;
- starting or continuing an interactive session in a chosen project.

Until now the module knew one folder, `claude.default_cwd`, for both running skills and finding project skills. The user asked for the default project and the terminal to be chosen in Settings.

The settings page had no place for a module's options: the Plugins tab only had switches, and the one module option on the page (`launcher.switch_to_english`) is hardcoded in the app. Adding Claude's options the same way would make the app know about Claude.

What Claude Code keeps on disk (CLI 2.1.x):
- One folder per project under `~/.claude/projects/`. The folder name is the path with `/` and `_` replaced by `-`, so it can't be turned back into the path.
- A `<session id>.jsonl` file per session. Its records carry `cwd` and `entrypoint` (`cli` and `claude-vscode` for interactive sessions; `sdk-cli` and `sdk-py` for `claude -p` and SDK runs, including QuickLaunch's own skill runs).
- Title records (`custom-title` from `/rename`, `ai-title` generated) appended again and again through a session, the latest last.
- Files can be hundreds of MB.

Ghostty 1.3 has an AppleScript dictionary with surface configurations (`initial working directory`, `initial input`). Its `-e` flag starts a separate app instance that quits when the command ends.

## Decision
- **Modules declare settings for the settings page** (`Contributions.setting(ModuleSetting)`).
  - A setting is a pick list for one key of the module's section: key, title, optional hint, the title of the unset default, and its options (value and title), loaded asynchronously when the page shows them, so they can be discovered, e.g. projects.
  - It doesn't change how the module reads the key; declaring it only puts it on the page. The page writes it to `preferences.yaml` like any module option (decision 0022), shows it read-only if `config.yaml` sets it, and keeps a set value that isn't among the options as an extra option.
  - The Plugins tab shows a plugin's settings under its switch while it's on. Settings of modules that aren't plugins have no place on the page yet; that's a later addition, if one needs it.
- **Claude projects come from Claude Code's history.**
  - Each session file is read at its head (about 64 KB: `cwd`, `entrypoint`, first prompt) and its tail (about 256 KB: the latest title). Results are cached by modification date.
  - Only interactive sessions count. Programmatic runs (`sdk-*`) are left out, so QuickLaunch's own skill runs don't fill the lists.
  - A project is a `cwd` that still exists, outside temporary folders, with its latest session's date.
  - A session's title is its `custom-title`, else its `ai-title`, else its first prompt.
- **`claude.default_project`** replaces `claude.default_cwd`: `recent` (the default, the project with the latest session) or a folder.
  - It's where `claude/<skill>` and `claude.skill` without `cwd` run.
  - Its `.claude/skills` are the project skills in the launcher. Other projects' skills aren't listed.
  - It's resolved when the launcher lists commands and when a skill runs, so `recent` follows the user's work.
- **`claude.terminal`:** `terminal` (Terminal.app, the default) or `ghostty`.
  - The command is typed into the terminal's own shell (Terminal's `do script`, Ghostty's `initial input`), so the user's PATH and shell setup apply and the shell stays open after Claude exits.
  - Both go through `osascript` with the values passed as arguments, never pasted into the script. Paths and ids are single-quoted for the shell.
- **New commands:**
  - `claude/projects` (Claude Projects) lists projects, most recent first. ⏎ starts a new session in one; ⌘⏎ continues its latest (`claude --continue`).
  - `claude/sessions` (Claude Sessions) lists the 50 latest sessions with their project and age. ⏎ resumes one in its folder (`claude --resume <id>`).
- **Not in this decision** (planned in the integration design):
  - running another project's skills by picking the project first, which needs an action to ask for text after a list;
  - replying in the panel, and "continue in terminal" from a panel run;
  - an "Ask Claude" fallback for typed text.

## Consequences
- Any plugin can now put options on the settings page without app changes, e.g. Obsidian's vault or Clarity's board.
- `default_cwd` is gone. A config that still sets it fails to load with an unknown-key error until the line is removed.
- With `recent`, the skills in the launcher change with the project last used in Claude Code, even if that session was in another tool (VS Code).
- The first Terminal or Ghostty command shows macOS's Automation prompt for QuickLaunch.
- History parsing depends on Claude Code's undocumented session format. Unknown records are ignored, and a file without a `cwd` is skipped.
