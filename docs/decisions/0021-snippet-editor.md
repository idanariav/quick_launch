# 0021. A snippet editor over the snippet files

Status: Accepted; amended by 0035 (the editor is shared with Claude prompts)
Date: 2026-10-21

## Context
Decision 0014 made each snippet a Markdown file, with "Open Snippets Folder" as the only way in. The user asked for a simple UI to edit and manage snippets instead of working with the files. The user decided (2026-10-21):
- the files stay the storage, and the editor reads and writes them;
- the editor is its own window, not a pane of Settings;
- it has an Insert menu for placeholders and checks the text as it's typed.

## Decision
- **Storage doesn't change.** The editor writes the same `<name>.md` files in the snippets folder, so they still sync, diff, and open in any editor. A file written by the editor has frontmatter only for the fields that are set:

  ```markdown
  ---
  title: "Signature"
  description: "Name and phone"
  ---
  Best,
  Idan
  ```

  Values are written as double-quoted (JSON-escaped) strings, which are valid YAML for any text, so no YAML writer has to be injected.
- **`SnippetEditor` lives in `QLModuleSnippets`.** It is a `@MainActor @Observable` class, like `Launcher` and `PreferencesPage` (decisions 0007, 0012), and holds the state the window renders:
  - the snippet list, with the selection;
  - the selected snippet's name, title, description and text;
  - the live check, which reuses `SnippetTemplate`: its problems, the fields the form will ask for, and whether it reads the selection or the clipboard.

  The composition root creates it and passes it to `SnippetsModule`. `SnippetEditorPresenting` is the window protocol; the app implements it.
- **Editing:**
  - **Saving:** title, description and text are saved as they change, like Settings.
  - **Renaming:** the name is the file name and the command id (`snippets/<name>`). It's renamed when the field is committed (⏎ or focus leaves it), not on every keystroke. A name must be non-empty, unused, and made of letters, digits, `-` and `_`; `open_folder` and `edit` are taken. The field says that shortcuts, keywords and aliases set for the old id don't follow it.
  - **New:** + creates `untitled.md` (`untitled-2.md`, … if taken) and selects it.
  - **Delete:** − asks first, then moves the file to the Trash.
  - **Afterwards:** each write rescans the snippets through `CommandCatalog.refresh(namespace:)`, which is new in core and refreshes one namespace's provider, so the launcher and hotkeys see the change at once without rescanning the apps.
  - **Outside edits:** the list is re-read when the window opens and when a snippet is selected.
- **Window (app):**
  - A sidebar of snippets with + and −. The detail shows Name, Title, Description, then the text, with an Insert menu above it and the check below it.
  - The text view is an `NSTextView`, because SwiftUI's `TextEditor` on macOS 14 can't insert at the cursor. Insert adds a placeholder at the cursor: Selection, Clipboard, Date, Date with format, Cursor, Text field, Dropdown. For a field, the name is selected, ready to type over.
  - **"Shortcut & keyword…"** opens Settings on that snippet's command. Those settings stay in one place (decision 0012).
  - It uses the shared style (decision 0020) and comes to the front like Settings.
- **Ways in:** a new command `snippets/edit` ("Edit Snippets"), and "Snippets…" in the menu bar. "Open Snippets Folder" stays.

## Consequences
- This amends decision 0014's "there's no snippet editor in the app". The file format and the commands it produces are unchanged.
- Renaming a snippet leaves its old id's shortcuts and keywords behind in `preferences.yaml` or `config.yaml`. Moving them along would mean editing both files, which the app doesn't do to `config.yaml`. The field warns about it instead.
- Frontmatter keys other than `title` and `description` aren't kept when the editor saves. None are defined (decision 0015 keeps keywords in config).
- An outside edit made while the window is open can be overwritten by the next change in the window.
