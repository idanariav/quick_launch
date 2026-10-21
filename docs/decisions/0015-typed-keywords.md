# 0015. Typed keywords: key-sequence triggers for any command

Status: Accepted
Date: 2026-10-21

## Context
The user wants text like `;sig` to expand a snippet as it's typed. They decided that a typed keyword and a hotkey are one concept, keystroke triggers, with the keyword as the general form (2026-10-21). So this is a change to the hotkey engine, not a snippet feature: any command can have a keyword, scoped to apps like any binding.

The user accepted the recommended answers to the open questions (2026-10-21):
- matching is by typed characters;
- a fixed set of reset events clears the buffer;
- erasing is always on;
- the buffer is memory-only and never logged;
- `then_pass_through` doesn't apply to keywords.

## Decision
- **Config:** `typed:` works wherever `keys:` does.
  - In `hotkeys:` it goes in place of `keys:`, with `app:`, `pass_through` and per-app precedence working the same way:

    ```yaml
    hotkeys:
      - { typed: ";sig", command: snippets/signature }
      - { typed: ";sig", app: com.apple.Terminal, action: pass_through }
    ```

  - Under `commands.<id>` (and so in `preferences.yaml` and on the settings page) it's another field, merged like `keys`.
  - **Checks:**
    - A keyword needs at least 2 characters and no whitespace.
    - The same keyword for the same app is the usual "already bound" error.
    - `then_pass_through` with `typed:` is an error.
    - Overlapping keywords get a warning, e.g. `;s` fires while typing `;sig`, since a keyword fires as soon as it's typed.
  - Snippet frontmatter doesn't declare keywords yet: snippets are discovered at runtime, and runtime-contributed triggers would be a new extension point. `commands.snippets/<name>.typed` (or the settings page) covers it for now.
- **Matching is by the characters typed,** so `;sig` follows the keyboard layout and won't match while typing in Hebrew. Chords keep matching physical keys.
  - The event tap passes each key press's characters along with its combo. They come from translating the key code and the event's modifier flags with the current layout (`UCKeyTranslate`), which is how apps interpret the key. The text a `CGEvent` carries can disagree with its own flags: right after a shifted key it may still be uppercase. Keywords then missed after a capital, which end-to-end testing showed. The layout is read on the main thread when the input source changes; the event's own text is the fallback for input sources without a layout.
  - `HotkeyRouter` keeps a buffer as long as the longest keyword, matched by suffix: candidates are indexed by their last character, and app-specific keywords are checked before global ones.
- **The buffer resets on:**
  - a press with ⌘ or ⌃;
  - a key that types no text or a control character (arrows, Return, Tab, Esc, Forward Delete, function keys);
  - a mouse click (the tap now also sees left and right mouse-down);
  - the frontmost app changing;
  - a chord binding running.

  Backspace removes the buffer's last character, so a corrected keyword still matches. While QuickLaunch itself is frontmost (launcher, settings), keywords don't fire. Secure Input stops the tap from seeing any keys, so nothing typed there is buffered.
- **When a keyword matches:**
  - its last key is swallowed;
  - the characters already typed are erased with that many synthetic Backspaces;
  - then the command runs.

  The erase count travels in the trigger (`HotkeyTrigger.eraseTyped`, `RunRequest.eraseTyped`). `ActionExecutor` posts the Backspaces first, through `KeySynthesizing`. Synthetic keys carry QuickLaunch's marker, so they never reach the buffer.
- **Privacy:** the buffer lives only in the router's memory, holds at most the longest keyword's length, and is never logged. Logs name the binding that ran, never what was typed.

## Consequences
- Every command (window layouts, apps, Claude skills, snippets) can have a keyword with no module changes.
- QuickLaunch now looks at the characters of every key press, not only its combo. That's still a lock and a few lookups on the tap thread, but it's the most sensitive code in the app. It stays small, and is tested without a tap.
- An app that handles Backspace oddly, or autocorrects the keyword, may be left with some of it. Turning erasing off per binding can be added if that happens.
