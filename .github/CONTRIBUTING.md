# Contributing

Thanks for contributing to Autostart Manager. Keep changes focused, testable, and consistent with the existing Bash code and Linux desktop behaviour.

## Before coding

For a behaviour change or a large feature, open an issue using the feature template before implementing it. Small bug fixes and documentation changes can go directly to a pull request.

Do not rename existing repository files. Keep user-facing changes synchronized between the English and Spanish README files when the change affects usage or configuration.

## Development rules

The program is a Bash script. Keep variables quoted, use `[[ ]]` for tests, prefer local function variables, and avoid unnecessary comments. Comments should explain non-obvious decisions, not restate the code.

Changes that touch autostart entries, systemd, cron, PolicyKit, or file persistence must preserve the existing safety checks and must not introduce direct unsafe writes.

## Tests

Run the complete local suite from the repository root:

```bash
tests/run_all.sh
```

Useful focused commands are:

```bash
tests/run_all.sh --list
tests/run_all.sh test_quality_regression.sh
```

Also run the static checks. `bash -n` only checks the first file it is given, so loop over the files:

```bash
bash tests/lint.sh
for file in script/*.sh tests/*.sh; do bash -n "$file"; done
```

`tests/lint.sh` needs ShellCheck 0.11.0, the version pinned in CI (`SHELLCHECK_BIN` selects the binary). The repository has no `.shellcheckrc`: the options live in the script, which ignores any local ShellCheck configuration, checks the program with no exclusions and the test suites with a short list of exclusions explained in its comments. A justified `# shellcheck disable=` comment is acceptable for test doubles and literal source patterns, never for the production script without a reason.

The real-dialog tests use Zenity under Xvfb. On a local Debian or Ubuntu based system, install `zenity`, `xvfb`, `imagemagick`, `python3-pil`, `fonts-dejavu-core` and `desktop-file-utils` to execute them instead of receiving an environment skip. Set `REQUIRE_UI_SMOKE=1`, `REQUIRE_SHELLCHECK=1`, `REQUIRE_PILLOW=1` and `REQUIRE_DESKTOP_VALIDATE=1` to turn a missing tool into a failure, as CI does.

Interface changes: Zenity 3.44 (GTK 3) and Zenity 4.x (GTK 4) are both in use, so only use options listed in `tests/test_zenity_compat.sh`. Run `bash tests/ui_tour.sh static` before and after your change; the scorecard must stay at 100. `bash tests/ui_tour.sh run OUT_DIR en /path/to/zenity browse` captures the real dialogs for a visual review.

For changes that affect a specific mechanism, verify at least one representative case for user autostart, system autostart, systemd user/system, or cron as appropriate. Do not modify real system configuration from an automated test; the test suite uses temporary fixtures and command stubs.

GitHub Actions runs `.github/workflows/quality.yml`, which performs ShellCheck, syntax validation, and the full suite, on every pull request and on every push to `Filonux-Box`. A branch without a pull request is not checked by itself: start the workflow by hand from the Actions tab (**Quality**, then **Run workflow**).

## Pull requests

Target `Filonux-Box`, the default branch. Describe what changed, why it changed, and how it was tested. Keep one logical change per pull request when practical.

Before submitting, confirm that:

- [ ] `tests/run_all.sh` passes.
- [ ] `bash tests/lint.sh` passes and every changed shell file passes `bash -n`.
- [ ] No generated files, credentials, or temporary files are included.
- [ ] User-facing documentation is updated when behaviour or requirements changed.
- [ ] New comments explain why, not what.

## Reporting issues

Use the issue templates. Include the Linux distribution and version, the desktop and X11/Wayland session, Bash and Zenity versions, exact reproduction steps, and relevant terminal output.

For security-sensitive problems, follow [`SECURITY.md`](SECURITY.md) instead of opening a public issue.
