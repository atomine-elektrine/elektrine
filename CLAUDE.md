# Project guidance for Claude Code

Elektrine is an Elixir umbrella app. See `README.md` for the app layout and
what each umbrella app under `apps/` owns.

## Git commits

- Do **not** add `Co-Authored-By: Claude ...` trailers to commit messages.
- Do **not** add `Claude-Session:` trailers to commit messages.
- Do **not** add "🤖 Generated with Claude Code" or similar attribution to
  commit messages or PR bodies.
- Keep commit messages clean: a concise subject line and a body describing the
  change only. Do not commit or push unless asked.

## Verifying changes

Always run the checks that CI runs before considering a change done — do not
report work as finished until format, compile, and credo pass.

After editing a file, run the fast per-file checks first:

- `mix format <file>` — format the file.
- `mix credo --strict <file>` — lint just that file (fast).

Then, before finishing, run the broader gate:

- `mix format --check-formatted` — CI fails if anything is unformatted.
- `mix compile --warnings-as-errors` — warnings fail the build; fix them.
- `mix credo --strict` — style/consistency must pass (whole project).
- `mix check` — the full CI gate (all of the above plus generated-artifact +
  legacy-marker checks, asset check, dep/hex audits, and `test`). Run this for
  anything non-trivial.

## Tests

- Run the whole suite from the umbrella root: `mix test`.
- Run one app's tests from its dir: `cd apps/elektrine_web && mix test`.
- Run a single file/line: `cd apps/<app> && mix test test/path/to_test.exs:42`.
- Prefer adding a regression test with any bug fix.

## Conventions

- Match the style and idioms of the surrounding code in each app.
- Keep domain logic in `apps/elektrine`; keep web/LiveView code in
  `apps/elektrine_web`. Don't reach across app boundaries casually.
