# 0017. Date and multi-choice parameters

Status: Accepted
Date: 2026-10-21

## Context
Clarity's "Create task" (PLAN M11) needs a do date and any number of tags. Parameters (decision 0010) have the kinds text, integer, boolean, duration and choice. A date as plain text would push the parsing and its errors into each module. Several tags as one choice are impossible. Both needs are general: snippets, Claude prompts and future integrations will want dates and multi-select too. So they belong in core, next to the existing kinds.

## Decision
Approved by the user on 2026-10-21, including the two choices below: a weekday counts today, and multi-select is a menu with checkmarks.

- **`date`** (`CommandParameter.Kind.date`):
  - **Accepted text:**

    | Text | Means |
    |---|---|
    | `today`, `tomorrow`, `yesterday` | as named |
    | a weekday (`fri`, `friday`) | the coming one, today included |
    | `+3d`, `+2w`, `-1d` | an offset from today in days or weeks |
    | `2026-11-02` | that date |

    Case doesn't matter.
  - **Value:** `ParameterValue.date(DateComponents)` with year, month and day; no time or time zone. `Arguments.date(id)` reads it.
  - **Resolved when the run starts,** in the current calendar. So `args: { do_date: tomorrow }` stays relative: it means tomorrow on every run, not the day the config was written.
  - **Form:** a text field like the others, with the accepted forms as its hint. As you type, the date it resolves to is shown ("Fri 24 Oct"), so a typo is visible before ⏎. There's no calendar picker, to keep the form keyboard-first; it can be added later.
- **`multi_choice`** (`CommandParameter.Kind.multiChoice([String])`):
  - **Value:** `ParameterValue.list([String])`, in the order of the options; `Arguments.list(id)` reads it.
  - **Text form:** comma-separated, e.g. `args: { tags: "errand, deep work" }`, or the same text in Settings or from the CLI. Unknown names are an error that lists the options. That means an option can't contain a comma; a module with such an option must rename it.
  - **Default:** a default may list several options. An optional one may be empty.
  - **Form:** a menu of checkable options whose label shows the current selection. ↓ opens it, Space toggles, and ⏎ submits the form.
- **Shared code learns both kinds.** Parsing and validation are in `CommandParameter.parse`, so config `args:`, the settings page's defaults, hotkeys and `quicklaunch run --arg` all get them with no changes. The control socket's `list` describes them as `date` and `multi_choice` (with `options`).
- **`parse` takes the current date,** defaulting to now, so tests can fix "today".

## Consequences
- Modules get dates and multi-select with validation, form controls and saved defaults for free.
- Snippets don't gain new placeholder syntax yet: `{input:…}` stays text. A typed placeholder like `{date:Due}` can come later on top of this.
- A saved default can stop being valid when a module's options change, e.g. a renamed Clarity tag. The form then shows the problem on that field, as it already does for choices.
