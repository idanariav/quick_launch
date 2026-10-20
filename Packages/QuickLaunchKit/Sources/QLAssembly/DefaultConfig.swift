/// Written to ~/.config/quicklaunch/config.yaml on first launch.
///
/// It documents every module's options, so update it when a module adds an
/// action type or setting. `QLAssemblyTests` checks that it loads without issues.
public enum DefaultConfig {
    public static let yaml = #"""
    # QuickLaunch configuration
    #
    # Changes are picked up when you save. If the file has errors, the menu bar icon
    # turns into a warning triangle, the menu lists each problem with its line number,
    # and the last valid config stays active.
    #
    # Key syntax: modifiers and one key joined with "+", e.g. "cmd+shift+k", "ctrl+alt+left", "f13".
    #   Modifiers: cmd, shift, alt (or opt), ctrl
    #   Keys: a-z, 0-9, f1-f20, space, return, tab, escape, delete, forwarddelete,
    #         left, right, up, down, home, end, pageup, pagedown, - = [ ] ; ' , . / \ `
    # Keys are physical positions on a US layout, so bindings work in any input language.
    #
    # Hotkey lookup: a binding for the frontmost app wins, then a global binding
    # (no "app"); otherwise the key reaches the app untouched.
    # To find an app's bundle ID, press ctrl+alt+b in it (see hotkeys below).
    #
    # The launcher (alt+space) searches every command: installed apps, the named
    # actions below, and more as modules add them.
    #
    # Hotkeys run without opening QuickLaunch; a small HUD shows progress, results
    # and errors. Each hotkey runs either:
    #   action:  a named action from "actions", or an inline { type: … } action
    #   command: any QuickLaunch command by id, e.g. apps/com.apple.Safari (every
    #            installed app) or actions/<name>
    # With a named action or a command, "input" and "output" (see below) can be
    # overridden on the hotkey itself.

    version: 1

    launcher:
      hotkey: alt+space

    claude:
      # binary: ~/.local/bin/claude     # auto-detected if omitted
      default_cwd: "~"
      # permission_mode: dontAsk        # acceptEdits | auto | bypassPermissions | manual | dontAsk | plan
      allowed_tools: [Read, Grep, Glob]

    # Named actions, referenced by name from hotkeys. Action types:
    #   apps.launch               bundle_id or path
    #   apps.frontmost_bundle_id  (default output: clipboard)
    #   window.move               op: left_half | right_half | maximize | center | next_display
    #   system.shell              run (input on stdin, stdout as output; both default to none)
    #   system.open_url           url
    #   system.send_keys          keys
    #   claude.skill              skill, cwd (default input: selection, output: panel)
    #   launcher.show
    #
    # Actions that work with text also take:
    #   input:  selection | prompt | clipboard | none
    #   output: panel | replace_selection | clipboard | none
    actions:
      left_half:  { type: window.move, op: left_half }
      right_half: { type: window.move, op: right_half }
      maximize:   { type: window.move, op: maximize }
      # Ask for text in the launcher and show the result there (find it by typing "shout").
      # shout: { type: system.shell, run: "tr a-z A-Z", input: prompt, output: panel }

    hotkeys:
      - keys: ctrl+alt+left
        action: left_half
      - keys: ctrl+alt+right
        action: right_half
      - keys: ctrl+alt+return
        action: maximize
      - keys: ctrl+alt+b
        action: { type: apps.frontmost_bundle_id }

      # Open (or focus) an app by command id.
      # - keys: ctrl+alt+s
      #   command: apps/com.apple.Safari

      # Per-app override: the same combo does something different in one app,
      # and nothing at all (the key passes through) in others.
      # - keys: cmd+shift+s
      #   action: { type: claude.skill, skill: summarize }
      # - keys: cmd+shift+s
      #   app: md.obsidian
      #   action: { type: claude.skill, skill: standardizing-topics, input: none }
      # - keys: cmd+shift+s
      #   app: [com.apple.Terminal, com.mitchellh.ghostty]
      #   action: pass_through

      # Text transform with any shell command: uppercase the selection in place.
      # - keys: ctrl+alt+u
      #   action: { type: system.shell, run: "tr a-z A-Z", input: selection, output: replace_selection }

      # Run an action and still deliver the original key (here: ⌘C still copies).
      # - keys: cmd+c
      #   app: com.google.Chrome
      #   action: { type: system.shell, run: "afplay /System/Library/Sounds/Tink.aiff" }
      #   then_pass_through: true

    """#
}
