# Security policy

agent-voice edits other tools' configuration files, stores an API key on disk,
runs a local synthesis daemon, and executes a hook on every model reply. Each
of those is a reason to take reports seriously and to be explicit about the
model.

## Reporting a vulnerability

Email **dan@halbonlabs.com** with the details, or open a GitHub security
advisory on this repository (Security > Advisories > Report a vulnerability).
Please do not open a public issue for anything exploitable. You will get an
acknowledgement within a week. There is no bounty programme; credit is given
in the changelog unless you ask otherwise.

## Threat model, in brief

- **The daemon is not a network service.** It binds loopback only, on an
  OS-assigned port, and requires a token from a file only the owning account
  can read (`0600`, owner-only ACL on Windows). It writes only allowlisted
  filenames inside its own state directory and bounds request sizes.
- **Model output is untrusted.** The spoken text comes from the model's reply,
  which can be steered by prompt injection in whatever the agent read. That
  text never reaches a shell; where it reaches an argv position it is behind
  `--` and a leading-dash strip.
- **The config file is data.** It is parsed key by key, never sourced or
  executed, because the installer writes it from pastes and the docs invite
  hand-editing.
- **Hook payload fields are untrusted.** `session_id` is clamped to
  `[A-Za-z0-9_-]` before it touches a file path.
- **Agent configs are edited surgically.** Entries are owned by an explicit
  marker, written atomically, and the pre-install original is kept as a
  one-time backup.
- **The ElevenLabs key** lives in a mode-600 (or owner-ACL) file and is passed
  to curl via stdin config, not argv.

## Out of scope

- Anything requiring the attacker to already run code as the same user
  account, other than the multi-user-machine cases listed above (same-user
  compromise defeats every tool that stores local state).
- The content the model chooses to put in its own summary.
