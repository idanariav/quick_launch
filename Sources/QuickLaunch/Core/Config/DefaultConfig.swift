/// Written to ~/.config/quicklaunch/config.yaml on first launch.
enum DefaultConfig {
    static let yaml = #"""
    # QuickLaunch configuration
    #
    # Changes are picked up when you save. If the file has errors, the menu bar icon
    # turns into a warning triangle and the last valid config stays active.
    #
    # Key syntax: modifiers and one key joined with "+", e.g. "cmd+shift+k", "ctrl+alt+left", "f13".
    #   Modifiers: cmd, shift, alt (or opt), ctrl
    #   Keys: a-z, 0-9, f1-f20, space, return, tab, escape, delete, forwarddelete,
    #         left, right, up, down, home, end, pageup, pagedown, - = [ ] ; ' , . / \ `
    # Keys are physical positions on a US layout, so bindings work in any input language.
    #
    # Hotkey lookup: a binding for the frontmost app wins, then a global binding
    # (no "app"); otherwise the key reaches the app untouched.
    # Find an app's bundle ID with: osascript -e 'id of app "Obsidian"'

    launcher:
      hotkey: alt+space

    claude:
      # binary: ~/.local/bin/claude     # auto-detected if omitted
      default_cwd: ~
      # permission_mode: dontAsk        # acceptEdits | auto | bypassPermissions | manual | dontAsk | plan
      allowed_tools: [Read, Grep, Glob]

    # Named actions, referenced by name from hotkeys.
    # Types:
    #   launch_app     bundle_id or path
    #   open_url       url
    #   shell          run
    #   window         op: left_half | right_half | maximize | center | next_display
    #   claude_skill   skill, input: selection | prompt | none, output: panel | replace_selection | clipboard, cwd
    #   send_keys      keys
    #   show_launcher
    #   pass_through
    actions:
      left_half:  { type: window, op: left_half }
      right_half: { type: window, op: right_half }
      maximize:   { type: window, op: maximize }

    hotkeys:
      - keys: ctrl+alt+left
        action: left_half
      - keys: ctrl+alt+right
        action: right_half
      - keys: ctrl+alt+return
        action: maximize

      # Per-app override: the same combo does something different in one app,
      # and nothing at all (the key passes through) in another.
      # - keys: cmd+shift+s
      #   action: { type: claude_skill, skill: summarize }
      # - keys: cmd+shift+s
      #   app: md.obsidian
      #   action: { type: claude_skill, skill: standardizing-topics, input: none }
      # - keys: cmd+shift+s
      #   app: [com.apple.Terminal, com.mitchellh.ghostty]
      #   action: pass_through

      # Run an action and still deliver the original key (here: ⌘C still copies).
      # - keys: cmd+c
      #   app: com.google.Chrome
      #   action: { type: shell, run: "afplay /System/Library/Sounds/Tink.aiff" }
      #   then_pass_through: true
    """#
}
