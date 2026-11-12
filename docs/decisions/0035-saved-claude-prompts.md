# 0035. Saved Claude prompts; template files move to core

Status: Accepted
Date: 2026-11-12

## Context
The user wants to save prompts that Claude runs on the selection without a project, e.g. "fix the grammar of this text". Until now Claude ran only skills: `claude.skill` always sends `/<skill> <input>`, in the default project. A one-off prompt needed a skill file in `~/.claude/skills`, or `system.shell` with `claude -p`, which skips the plugin's settings and doesn't stream into the panel.

The user asked for a "prompt drawer" like snippets, and decided (2026-11-12):
- prompts use the snippet placeholders, so a prompt reads the selection only if it has `{selection}`;
- the editor is the snippet editor, shared, not a copy;
- prompts run in the home folder unless a prompt says otherwise.

Snippets' template parser, folder scanning and editor all lived in `QLModuleSnippets`. Modules can't share code with each other, so the Claude module couldn't use them.

## Decision
- **Template files move to core** (`QLCore/Templates`), since two features now use them:
  - `TextTemplate` is the snippet parser (decision 0014), unchanged except for `allowsCursor`. Where text isn't pasted, `{cursor}` is a problem.
  - `TemplateFolder` and `TemplateFile` replace `SnippetLibrary` and `Snippet`. Frontmatter keys other than `title` and `description` are kept as `metadata`.
  - `TemplateFileEditor` replaces `SnippetEditor`, and `TemplateFileEditorPresenting` replaces its window protocol.
  - A `TemplateFileKind` describes each kind of file: noun, window title, icon, whether `{cursor}` is allowed, reserved names, the namespace to refresh, the command id for a file name, and extra frontmatter fields. An extra field is a text field, or a pick list when it has options. The editor shows these fields under Description, and the Insert menu leaves out Cursor Position when the cursor isn't allowed.
  - Snippets declare `SnippetsModule.fileKind`, and their behavior doesn't change.
- **The app's window is generic.** `TemplateFilesWindowController` renders any `TemplateFileEditor`. The app makes one for snippets and one for prompts.
- **Prompts are part of the Claude plugin** and switch off with it.
  - **Files:** one `.md` file per prompt in `claude.prompts_directory` (default `~/.config/quicklaunch/prompts`).
  - **Commands:** each file becomes `claude/prompts/<file name>`. The `prompts/` prefix keeps prompts apart from skills' `claude/<skill>`, since skill names have no `/`. The module's provider combines skills and prompts.
  - **Frontmatter:**
    - `title` and `description`, as for snippets;
    - `cwd`: the folder to run in, by default the home folder, so no project's files, `CLAUDE.md` or skills apply;
    - `output`: `replace_selection` or `clipboard`, by default the panel. An unknown value is shown as a warning in the subtitle, and the panel is used.
  - **Input:** `selection` only if the text has `{selection}`, otherwise none. Fields are parameters, as for snippets.
  - **Running:** the filled-in text runs with `claude -p` and the plugin's `binary`, `permission_mode` and `allowed_tools`. This is the same run as skills: `ClaudeRun` is shared, so streaming, error results and denied tools behave the same. An empty prompt, or a `cwd` that isn't a folder, fails before Claude starts.
  - **Ways in:** `claude/edit_prompts` ("Edit Claude Prompts") and "Claude Prompts…" in the menu bar open the editor.

## Consequences
- A third kind of template file needs only a `TemplateFileKind`, a `TemplateFolder` and an editor window. Neither core nor the window has to change.
- `ClaudeModule` now needs a clipboard and the prompt editor. Tests that build it use a main-actor helper.
- A prompt whose text starts with `/` runs as a skill invocation. That's allowed, and is a way to pass a skill fixed text.
- "Claude Prompts…" in the menu bar does nothing useful when the Claude plugin is off. The command isn't there, and the run says so.
- Renaming a prompt leaves its old id's shortcuts behind, as for snippets (decision 0021).
