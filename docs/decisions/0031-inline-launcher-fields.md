# 0031. Inline fields: the selected command's parameters under the search field

Status: Accepted (amends 0010's "from the launcher, always" form)
Date: 2026-10-23

## Context
From the launcher, a command with parameters ran in two steps: ⏎ on the result, then a form (decision 0010) to review the values and ⏎ again. The user wants a single typing streak instead: select a command, press ⇥ into its fields, type values, ⇥ between them, and ⏎ to run. That's the Raycast model.

The form is asked for by the executor *during* the run, after it resolves the values (defaults, then `commands.<id>.args`, then the binding's `args:`). For the fields to show before the run, the launcher needs those values up front, and the executor needs to know that the user already answered.

The user chose these answers (2026-10-23):
- the fields go in a strip under the search field, not inside it, since commands have up to 5 parameters;
- every field is typed text, with ↑/↓ stepping through yes/no and choice options;
- the form remains only as a fallback.

## Decision
- **Core:** `RunRequest.answers: FormAnswers?` carries what the user typed before the run.
  - **Priority:** typed values win over every configured layer. `ArgumentResolver.resolve(typed:)` reports their problems without a config path.
  - **When the executor still asks:** with answers, it shows the form only when something is missing (a required value, text input, or nothing selected) or a typed value doesn't parse. The form then opens prefilled with the typed values and shows the errors. Without answers, nothing changes: hotkeys stay headless if they can, and a launcher run with no answers still gets the form.
  - **`ArgumentResolver` is public,** so the launcher shows the same values the run would use.
- **Launcher:**
  - **What's shown:** `inlineForm` is the selected result's text input (`input: prompt`) and parameters.
  - **Empty fields:** an empty field shows the value the run will use, greyed (yes/no reads `yes`/`no`). If there's no value, it shows the hint or the options. An empty field sends nothing, so the run uses its own value.
  - **Keys:**
    - ⇥ and ⇧⇥ move from the search field through the fields, caught by the window like ⏎.
    - ⏎ runs from any field.
    - Esc in a field returns to the search field.
    - ↑/↓ in a yes/no or choice field steps through its options; in other fields the arrows do nothing, so the selected command doesn't change under the user.
    - § in a field is typed, not a number prefix.
  - **Completion:** a typed prefix that matches only one option completes to it (`hi` → `high`, `n` → `no`), for multi-choice too. An ambiguous prefix is sent as typed, and the form then names the options.
  - **Texts are kept per command** until the launcher closes, so changing the query and coming back keeps them.
  - **Window:** ⏎ hides the window unless the run will still ask (text input, or a required value nobody gave) or shows output. That avoids a hide-then-show flicker.
- **Every launcher run sends answers** when the command has fields, including ⌘1–9. So ⏎ on a command with defaults runs at once instead of opening the form.

## Consequences
- Any module's parameters get inline fields with no module changes.
- An optional parameter that has a default can't be cleared to "none" inline, because empty means the default. The settings page or a hotkey's `args:` covers that.
- Yes/no and choice fields are text, not switches or menus. That keeps them keyboard-first, but the options are only visible as the placeholder or by stepping through them.
- The form stays for hotkeys (`ask: true`, missing values) and as the launcher's fallback, so it keeps its tests and behavior.
