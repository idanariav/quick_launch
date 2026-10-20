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
    # The launcher (alt+space) searches every command: installed apps, window
    # layouts, System Settings panes, system toggles, Claude Code skills, and the
    # named actions below.
    #
    # Hotkeys run without opening QuickLaunch; a small HUD shows progress, results
    # and errors. Each hotkey runs either:
    #   action:  a named action from "actions", or an inline { type: … } action
    #   command: any QuickLaunch command by id:
    #            apps/<bundle id>        every installed app, e.g. apps/com.apple.Safari
    #            window/<op>             any window.move op below, e.g. window/left_half
    #            settings/<pane id>      every System Settings pane, e.g.
    #                                    settings/com.apple.wifi-settings-extension
    #            settings/toggle_dark_mode
    #            system/lock_screen, system/sleep_display, system/show_desktop
    #            claude/<skill>          every Claude Code skill in ~/.claude/skills, the
    #                                    default_cwd project and enabled plugins, e.g.
    #                                    claude/writing-skills or claude/<plugin>:<skill>
    #            actions/<name>          the named actions below
    # With a named action or a command, "input" and "output" (see below) can be
    # overridden on the hotkey itself.

    version: 1

    launcher:
      hotkey: alt+space

    # Claude Code skills run as `claude -p "/<skill> <input>"` and stream their reply
    # into the launcher panel. Tools outside allowed_tools are denied (the run then
    # fails and says which tool to add).
    claude:
      # binary: ~/.local/bin/claude     # default: claude on your login shell's PATH
      default_cwd: "~"                  # where skills run; its .claude/skills are listed too
      # permission_mode: dontAsk        # acceptEdits | auto | bypassPermissions | manual | dontAsk | plan
      allowed_tools: [Read, Grep, Glob]

    # Named actions, referenced by name from hotkeys. Action types:
    #   apps.launch               bundle_id or path
    #   apps.frontmost_bundle_id  (default output: clipboard)
    #   window.move               op: left_half | right_half | top_half | bottom_half |
    #                                 top_left | top_right | bottom_left | bottom_right |
    #                                 maximize | center | next_display | previous_display
    #   system.shell              run (input on stdin, stdout as output; both default to none)
    #   system.open_url           url
    #   system.send_keys          keys
    #   claude.skill              skill, cwd (default input: selection, output: panel)
    #   launcher.show
    #
    # Actions that work with text also take:
    #   input:  selection | prompt | clipboard | none
    #   output: panel | replace_selection | clipboard | none
    # With nothing selected, input "selection" asks for the text instead.
    # Esc in the panel stops a run; clicking elsewhere hides it, and alt+space brings it back.
    actions:
      # Ask for text in the launcher and show the result there (find it by typing "shout").
      # shout: { type: system.shell, run: "tr a-z A-Z", input: prompt, output: panel }

    hotkeys:
      - keys: ctrl+alt+left
        command: window/left_half
      - keys: ctrl+alt+right
        command: window/right_half
      - keys: ctrl+alt+return
        command: window/maximize
      - keys: ctrl+alt+b
        action: { type: apps.frontmost_bundle_id }

      # Open (or focus) an app by command id.
      # - keys: ctrl+alt+s
      #   command: apps/com.apple.Safari

      # Run a Claude Code skill on the selected text, or paste its reply over the selection.
      # - keys: ctrl+alt+k
      #   command: claude/summarize
      # - keys: ctrl+alt+shift+k
      #   command: claude/summarize
      #   output: replace_selection

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
