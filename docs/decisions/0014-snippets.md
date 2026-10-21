# 0014. Snippets: files, placeholders as parameters, pasting with a caret position

Status: Accepted
Date: 2026-10-21

## Context
The user asked for saved text with dynamic placeholders, such as the selected text or a dropdown with a default, inserted from the launcher or by a hotkey (PLAN M9). A typed keyword that expands a snippet is the general key-sequence trigger of M9b, which gets its own record. Since M7, commands can ask for values through one form, and since M5 core can paste text over the selection while keeping the clipboard. Snippets should reuse both rather than grow their own versions.

## Decision
- **One Markdown file per snippet** in `~/.config/quicklaunch/snippets/`. The folder can be changed with `snippets.directory`.
  - **Id:** the file name without `.md` is the command name. `signature.md` is `snippets/signature`, so it can be searched, bound with `hotkeys:` or `commands.<id>.keys`, given aliases, switched off or made a favorite like any command.
  - **Frontmatter is optional:**
    - `title`: the name shown; defaults to the file name.
    - `description`: the subtitle; defaults to the text's first line.
    - M9b will add a typed trigger here.
  - **Body:** inserted as written; the single newline editors add at the end is dropped. Hidden files and other extensions are ignored.
- **Placeholders**, in braces:

  | Placeholder | Inserts |
  |---|---|
  | `{selection}` | the selected text |
  | `{clipboard}` | the clipboard's text |
  | `{date}`, `{date:EEEE d MMM}` | today, as `yyyy-MM-dd` or in the given Unicode date pattern |
  | `{cursor}` | nothing; the caret ends up here (once per snippet) |
  | `{input:Name}`, `{input:Name=default}` | a text field |
  | `{choice:Name\|a\|b\|c}` | a dropdown; the first option is the default |

  - **Fields are M7 parameters.** `{input:…}` and `{choice:…}` become `CommandParameter`s with id and title `Name`. The same form asks for them, and `commands.<id>.args` and a binding's `args:` work unchanged.
    - A field without a default is required, so a hotkey run asks for it.
    - A field used twice is asked once.
  - **Escaping:** `{{` and `}}` are literal braces.
  - **Problems:** an unknown or malformed placeholder is inserted as written. It's logged, and the snippet's subtitle starts with a warning, so the snippet still works and the problem is visible where it's used.
- **Running it uses the core text pipeline:**
  - **Input:** if the snippet uses `{selection}`, its input is `selection`, read before anything else while the user's app has focus. As with any selection command, if nothing is selected the form asks for that text too. Other snippets take no input.
  - **Output:** `replace_selection`, which pastes at the cursor (over the selection, if any) and restores the clipboard.
  - **Placing the caret (new in core):** `invocation.result.placeCaret(charactersFromEnd:)` lets an action say where the caret goes after a pasted output. `SelectionService.replaceSelection(with:in:caretBack:)` then presses ← that many times after pasting. This is a general mechanism, not specific to snippets.
- **Module:** `QLModuleSnippets`.
  - **Discovery:** the folder is scanned when first needed and rescanned whenever the catalog refreshes (the launcher opening). That's cheap for a folder of text files, and in-place edits don't change the folder's modification time, which rules out checking that instead.
  - **Services:** the clipboard and the YAML parser come through its initializer.
  - **Extra command:** `snippets/open_folder` creates the folder if needed and opens it. A snippet file of that name is hidden by it.
- **Frontmatter moves to core.** Splitting a Markdown file into its `---` block and body is a small text function (`Frontmatter`, with `YAMLParsing`), used by both the Claude skills and snippets. Modules can't share code with each other otherwise.

## Consequences
- Snippets get search, hotkeys, aliases, switching off, favorites, saved defaults and the form at no extra cost. M9b's typed trigger is the only snippet-specific trigger left.
- Snippets are edited in any text editor; there's no snippet editor in the app. "Open Snippets Folder" is the way in.
- The caret is placed with arrow keys, so it lands correctly in plain text fields and editors. Apps that reformat pasted text (rich text auto-formatting) may put it elsewhere.
- Nothing selected while a snippet uses `{selection}` asks for the text, as other selection commands do. If that turns out to be annoying for snippets, a per-placeholder fallback (`{selection?}`) can be added later.
