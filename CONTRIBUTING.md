# Contributing to SessionBridge

Contributions are welcome — especially **adapters** for more coding CLIs.
This project runs people's signed-in CLIs on their own machines, so the bar is
evidence: every flag in an adapter must be traceable to the CLI vendor's own
documentation or `--help` output.

## Adapter contributions (the most valuable kind)

An adapter is one JSON file in `adapters/`, named `<id>.json`. To add one:

1. Copy `adapters/generic.example.json` and rename it.
2. Fill in **only verified facts**:
   - `executable.names` / `executable.paths` — how to find the binary.
   - `versionArgs` — prints the version and exits.
   - `authCheck.args` — a cheap, non-interactive command that exits 0 when
     signed in and non-zero otherwise (no model call). If the CLI has none,
     set `authCheck` to `null` and say why in `notes`.
   - `promptDelivery` — `stdin` if the CLI can take the whole prompt on stdin
     in its noninteractive mode; otherwise `argument`, with
     `invoke.promptArgs` showing exactly where the prompt goes
     (e.g. `["{prompt}"]` or `["--message", "{prompt}"]`).
   - `modes` — map the common scale (`readonly` / `accept-edits` / `auto`) to
     the CLI's own flags. `readonly` must not be able to edit files. If the
     CLI has no equivalent for a tier, omit that key — the runner will reject
     jobs asking for it, which is the correct behavior.
   - `modelArgs` / `effortArgs` — templates with a `{value}` placeholder;
     `efforts` lists the allowed values, or is `null` if the CLI's values are
     free-form (they are still pattern-checked by the runner).
3. Set `status` honestly:
   - `verified` — every fact sourced from the vendor's docs or a live binary,
     with the sources listed in `sources`. Where a flag's *form* is unusual
     (composed values, flag ordering, sentinel arguments), `verified` also
     requires a captured `--help` transcript or a live end-to-end run on
     record — if the composed form is only inferred from docs, the status is
     `community` until someone confirms it on a real binary.
   - `community` — flags documented, but the mode mapping is your inference or
     not yet exercised end-to-end. Most new adapters land here.
   - `unverified` — a stub. It will not be merged as a runnable adapter.
4. List your sources (doc URLs) in `sources`, and use `notes` for caveats:
   deprecated flags you deliberately avoided, dangerous flags the adapter must
   never emit, and anything a user should confirm against their installed
   version.
5. Never add a bypass/skip-permissions flag to any mode. If a CLI's only
   noninteractive path requires one, the adapter is not a fit — open an issue
   instead.

If you can, include the `--help` output (or a link to it) in your PR
description so reviewers can re-verify without installing the CLI.

## Runner and client changes

- The runner targets **Windows PowerShell 5.1** (the version that ships with
  Windows) and must also run on PowerShell 7. Keep it plain ASCII, avoid
  syntax newer than 5.1, and do not add module dependencies.
- Any change to job validation, the mode ceiling, or status semantics needs a
  matching test in `tests/run-tests.ps1` — the guards are only worth having
  if the tests prove they can fire.
- Run the harness before submitting: it needs no real CLI.

  ```
  pwsh -NoProfile -File tests/run-tests.ps1     # or powershell on Windows
  ```

## Documentation

If behavior changes, update the docs in the same PR: `README.md` for the
overview, `docs/install.md` for setup steps, `docs/setup.md` for transports,
`docs/customization.md` for knobs and extension points, `docs/examples.md` for
workflows, and `SECURITY.md` if the threat model moves. Mark anything not
shipped as an **extension point** or **roadmap** item — the docs must never
describe aspirations as features.
