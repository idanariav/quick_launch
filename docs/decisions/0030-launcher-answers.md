# 0030. Launcher answers: an answerer extension point, and a Calculator plugin

Status: Accepted
Date: 2026-10-23

## Context
The user wants the launcher to answer some queries directly, on a card between the search field and the results: math (`100+100`), dates (`tomorrow`, `today's date`), times across time zones (`2pm IDT EST time`) and unit conversions (`20 cm in inches`). The launcher only searched commands. ARCHITECTURE §10 already said that live queries per keystroke would be a new `Contributions` method, so this is a missing extension point, not a feature to add inside `Launcher`.

## Decision
- **Core: `contributions.answerer(QueryAnswerer)`.** A `QueryAnswerer` turns a query into an `Answer` (title, subtitle, icon, the text to copy) or `nil`. `AppConfig.answerers` lists them in module order, then registration order. `AppAssembly` hands them to the launcher on each accepted load.
- **Answerers are synchronous.** They run on the main actor at every keystroke, so they must be fast and do no I/O. That way an answer can never be stale, and the card never flickers while typing. An answer that needs I/O (currency rates) would need an async variant with a per-query generation; that's left until something needs it.
- **The launcher shows the first answer.** Only a search of everything is answered: a list's search (favorites, recents) and a choice list aren't.
  - The card is selected when it appears, and ⏎ copies the answer and closes (the user chose this, like Raycast and Alfred).
  - ↓ moves into the results and ↑ from the first result goes back. ⌘1–9 still run results, and ⌘D ignores the card.
  - The launcher gets a `ClipboardService` for the copy.
- **`QLModuleCalculator`**, a plugin (`calculator.enabled: false` turns it off) with four answerers. Dates come before math, so `2026-11-02` is a day, not 2013.
  - **Math:** a small recursive-descent parser for `+ - * / ^` (also `× ÷ **`), parentheses, unary minus, `sqrt()` and `pi`. It doesn't use `NSExpression`, which raises Objective-C exceptions that Swift can't catch on input like `1+`. A bare number isn't answered.
  - **Units:** conversion is Foundation's `Measurement`, and the module only knows the units' names. Km/h is redefined exactly, because Foundation's is rounded (0.277778 m/s). Days and weeks are added as durations.
  - **Dates:** the day is read by `DateText`, as date parameters are (decision 0017), plus phrasing such as "today's date" and "in 3 days". An abbreviated weekday alone (`mon`) isn't answered: it's more likely the start of a command's name.
  - **Times:**
    - Forms: `time`, `time in tokyo`, `est time`, and a time converted between zones (`2pm IDT EST time`, `14:00 london to new york`, `9am pt`).
    - Zones: Foundation's abbreviations, which follow daylight saving (EST is New York's time all year), plus `IDT`/`israel`, `ET/CT/MT/PT`, and city names and identifiers from the time zone database. `IST` stays India's, as in Foundation.
    - The card names the cities it used, so a misread abbreviation shows.
- Numbers in answers use `.` as the decimal point, matching what the parsers read. Dates and times follow the user's locale.

## Consequences
- A future answerer (currency, a dictionary, a color) is a module calling `contributions.answerer`, with no launcher change.
- An exact query that is also the start of a command's name (`time` before "Time Machine") selects the answer, so ⏎ copies it. Typing on, ↓ or ⌘1 reaches the command. Answerers must therefore stay strict about what they recognize.
- A plugin's answerers can't be ordered against another module's except through the module list in `AppAssembly`.
