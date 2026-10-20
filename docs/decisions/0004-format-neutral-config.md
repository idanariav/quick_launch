# 0004. Modules read a format-neutral config tree through `ConfigReader`

Status: Accepted
Date: 2026-10-20

## Context
M1 decoded config with Codable structs mirroring the YAML, validated them in one central parser, and detected unknown keys with a separate walker that had to be kept in sync with the structs. Errors had paths but no line numbers. For modules to own their sections, each one needs a way to decode and validate that produces consistent errors and doesn't depend on YAML.

## Decision
`QLConfigYAML` converts YAML into a `ConfigValue` tree that records the line and column of every node. Modules read it only through `ConfigReader`, which provides typed accessors (`value`, `list`, `oneOrMore`, `section`, `sections`, `namedSections`, plus `required` variants). Errors carry their path and line automatically. Every key a reader is asked about counts as known; leftover keys are reported as unknown when loading finishes. Value types conform to `ConfigScalar`, and string enums adopt `ConfigEnum`.

## Consequences
- Unknown-key detection can't drift from what modules actually read, and typos such as `apps:` for `app:` are caught.
- Every error has a line number, and issues are sorted by line.
- Core never imports Yams. Another format, or a GUI that edits the config, only needs to produce a `ConfigValue`.
- Decoders must read every key before giving up; otherwise valid keys get reported as unknown. This is documented in ARCHITECTURE.md §6 and covered by tests.
