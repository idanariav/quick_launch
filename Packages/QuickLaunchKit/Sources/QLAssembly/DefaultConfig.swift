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
    #            system/caffeinate       keep the Mac awake (parameters: duration, display)
    #            system/caffeinate_stop
    #            claude/<skill>          every Claude Code skill in ~/.claude/skills, the
    #                                    default project and enabled plugins, e.g.
    #                                    claude/writing-skills or claude/<plugin>:<skill>
    #            claude/projects, claude/sessions   start, continue or resume a session
    #            shortcuts/<name>        every Apple Shortcut, its name lowercase with
    #                                    "_" for spaces, e.g. shortcuts/game_mode
    #            actions/<name>          the named actions below
    # With a named action or a command, "input" and "output" (see below) can be
    # overridden on the hotkey itself.
    #
    # Some commands take parameters, e.g. system/caffeinate's duration. From the
    # launcher you fill them in (prefilled with the defaults). A hotkey uses its own
    # "args", then the defaults under "commands" below, then the command's defaults,
    # and only asks for what's still missing; "ask: true" always asks.

    version: 1

    launcher:
      hotkey: alt+space
      # switch_to_english: true   # your English keyboard while it's open, the previous one after

    # Plugins (Claude, Clarity) can be switched off as a whole, in Settings → Plugins
    # or here with "enabled: false"; they then load nothing.

    # Claude Code skills run as `claude -p "/<skill> <input>"` and stream their reply
    # into the launcher panel. Tools outside allowed_tools are denied (the run then
    # fails and says which tool to add). "Claude Projects" starts a session in a project
    # (cmd+return continues its latest) and "Claude Sessions" resumes one, in a terminal.
    # The terminal and default project can also be set in Settings → Plugins.
    claude:
      # enabled: true   # false switches the plugin off
      # binary: ~/.local/bin/claude     # default: claude on your login shell's PATH
      # default_project: recent         # recent (your latest Claude Code session's folder)
      #                                 # or a folder: where skills run; its skills are listed
      # terminal: terminal              # terminal | ghostty
      # permission_mode: dontAsk        # acceptEdits | auto | bypassPermissions | manual | dontAsk | plan
      allowed_tools: [Read, Grep, Glob]

    # Snippets: every .md file in the folder is a command, snippets/<file name>, that
    # pastes its text at the cursor ("Open Snippets Folder" in the launcher). Optional
    # frontmatter: title, description. Placeholders:
    #   {selection} {clipboard} {date} {date:EEEE d MMM} {cursor}
    #   {input:Name} {input:Name=default} {choice:Name|first|second}   asked in a form
    #   {{ and }} are literal braces
    snippets:
      # directory: ~/.config/quicklaunch/snippets

    # Clarity, through its `clarity` CLI (Clarity → Settings → Advanced → Command-Line Tool):
    # "Create Clarity Task" (from the selection), "Clarity Tasks" (⏎ completes, ⌘⏎ opens),
    # "Complete Habit: …" for each habit, and "Clarity View: …" for each saved view.
    clarity:
      # enabled: true   # false switches the plugin off
      # executable: clarity   # default: clarity on your login shell's PATH
      # board: Personal       # where new tasks go; default: the project's board, else the first

    # Arc: "New Arc Tab" (a URL or a web search, from the selection), "Copy Arc Tab as
    # Markdown Link", "Arc Tabs" (⏎ switches, ⌘⏎ closes), "Arc Space: …" for each space.
    # The first use asks to let QuickLaunch control Arc.
    arc:
      # enabled: true   # false switches the plugin off
      # search_engine: google   # google | duckduckgo | kagi | perplexity | bing

    # Calendar, through macOS's calendars: "Join Next Meeting", "Agenda" (⏎ shows the
    # event, ⌘⏎ joins its call), "New Calendar Event" and "Open Next Meeting". The menu
    # bar counts down to the next meeting ("Dev sync in 45m"); clicking it joins the
    # call, or shows the event. The first use asks for access.
    calendar:
      # enabled: true   # false switches the plugin off
      # agenda_days: 2   # today and tomorrow
      # menu_bar: title   # title ("Dev sync in 45m") | time (an icon and "45m") | off
      # menu_bar_hours: 1   # show meetings starting within this many hours (1–24)

    # Obsidian, through its CLI (Obsidian → Settings → General → Command line interface):
    # "Capture to Daily Note", "Search Obsidian", "New Obsidian Note", "Obsidian Tasks".
    obsidian:
      # enabled: true   # false switches the plugin off
      # vault: My Vault               # default: the vault opened last
      # daily_folder: Calendar/Daily  # default: Obsidian's Daily notes plugin
      # daily_format: YYYY-MM-DD      # Obsidian's date format
      # new_note_folder: Inbox        # default: the vault's root

    # Screen OCR: "Copy Text from Screen (OCR)": select an area of the screen and copy
    # the text in it, recognized on this Mac. The first use asks for Screen Recording access.
    ocr:
      # enabled: true   # false switches the plugin off
      # languages: [en-US, fr-FR]   # default: detected automatically
      # language_correction: false  # default: true; false keeps digits from becoming letters (0 → O)

    # Shortcuts: each of your Apple Shortcuts is a command, run with `shortcuts run`.
    # To turn on a Focus, make a shortcut with the "Set Focus" action and run that.
    shortcuts:
      # enabled: true   # false switches the plugin off

    # Calculator: answers what you type in the launcher on a card above the results;
    # ⏎ copies it. Math ("100+100", "2^10", "sqrt(2)"), units ("20 cm in inches",
    # "70 f to c"), dates ("tomorrow", "today's date", "in 3 days") and times across
    # time zones ("time in tokyo", "2pm IDT EST time").
    calculator:
      # enabled: true   # false switches the plugin off

    # Per-command settings, by command id (QuickLaunch Settings, in the menu bar menu,
    # shows each command's id):
    #   args      default parameter values
    #   aliases   extra names the launcher search matches
    #   keys      a global shortcut that runs the command
    #   typed     a keyword that runs it when typed anywhere, e.g. ";sig"
    #   disabled  true: hidden from search, and its shortcuts don't run
    #   external  true: quicklaunch://run/<id> links may run it (e.g. a Stream Deck
    #             button). Any app or web page can open a link, so it's off by default.
    #             The `quicklaunch` CLI (`make install-cli`) can run any command.
    # QuickLaunch Settings saves the same fields to preferences.yaml next to this file;
    # a field set here wins and is read-only there.
    commands:
      # system/caffeinate: { args: { duration: 2h, display: false } }
      # window/maximize: { aliases: [max, full], keys: ctrl+alt+m }
      # system/sleep_display: { disabled: true }
      # window/left_half: { external: true }  # quicklaunch://run/window/left_half

    # Commands listed first when the launcher opens, in this order. The launcher's ⌘D
    # and QuickLaunch Settings save them to preferences.yaml instead; a list here wins.
    favorites:
      # - apps/com.apple.Safari
      # - window/maximize

    # Named actions, referenced by name from hotkeys. Action types:
    #   apps.launch               bundle_id or path
    #   apps.frontmost_bundle_id  (default output: clipboard)
    #   window.move               op: left_half | right_half | top_half | bottom_half |
    #                                 top_left | top_right | bottom_left | bottom_right |
    #                                 maximize | center | next_display | previous_display
    #   system.shell              run (input on stdin, stdout as output; both default to none)
    #   system.open_url           url
    #   system.send_keys          keys
    #   claude.skill              skill, cwd (default: the default project; input: selection, output: panel)
    #   launcher.show
    #   macro.run                 steps: commands or actions to run in order (see below)
    #
    # Actions that work with text also take:
    #   input:  selection | prompt | clipboard | none
    #   output: panel | replace_selection | clipboard | none
    # With nothing selected, input "selection" asks for the text instead.
    # Esc in the panel stops a run; clicking elsewhere hides it, and alt+space brings it back.
    actions:
      # Ask for text in the launcher and show the result there (find it by typing "shout").
      # shout: { type: system.shell, run: "tr a-z A-Z", input: prompt, output: panel }

      # A macro runs its steps in order; the first that fails stops the rest. Write one
      # here, or make it in the Macros window (menu bar → Macros…), which saves it to
      # preferences.yaml. A step is "command" (with "args": values are set here, a step
      # never asks), "action" (a name or an inline action) or "wait" (a pause). A macro
      # can't run another macro.
      # deep_work:   # turn on a Focus (a shortcut with "Set Focus"), then more
      #   type: macro.run
      #   steps:
      #   - command: shortcuts/work
      #   - { command: system/caffeinate, args: { duration: 2h } }
      #   - wait: 2s
      #   - command: apps/com.apple.Notes

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

      # Keep the Mac awake for 2 hours, or ask how long each time. The menu shows it while
      # it's on, with a Stop item.
      # - keys: ctrl+alt+c
      #   command: system/caffeinate
      #   args: { duration: 2h }
      # - keys: ctrl+alt+shift+c
      #   command: system/caffeinate
      #   ask: true

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

      # A typed keyword instead of a chord: typing ;wl anywhere tiles the window left. The
      # keyword is erased first. It matches the characters typed (so it follows the
      # keyboard layout) and starts over on arrows, Return, clicks or switching apps.
      # - typed: ";wl"
      #   command: window/left_half

      # Run an action and still deliver the original key (here: ⌘C still copies).
      # - keys: cmd+c
      #   app: com.google.Chrome
      #   action: { type: system.shell, run: "afplay /System/Library/Sounds/Tink.aiff" }
      #   then_pass_through: true

    """#
}
