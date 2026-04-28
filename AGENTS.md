# AGENTS.md

## Purpose

This repository stores opinionated global package manager config templates and a PowerShell script that syncs those settings onto Windows machines.

## Current Scope

- Windows only
- Config sync only
- No package manager installation
- No Linux, WSL, or macOS automation yet

Do not describe planned platforms as currently supported.
Do not delete Linux or macOS path markers from templates; they are kept for future platform scripts.

## Core Design Rules

1. Keep the template-driven design.
2. Prefer adding or updating files under `templates/` over hardcoding special cases in `install-windows-configs.ps1`.
3. Preserve non-managed user settings in destination config files.
4. Make the smallest correct change.
5. Keep YAML templates top-level only unless you also extend merge support safely.
6. Keep template comments machine-readable only; avoid extra explanatory comments unless they are required by the script.

## Script Behavior To Preserve

The main script currently:
- discovers templates automatically from `templates/`
- reads `Windows-Path` markers from template comments
- expands environment variables and `~`
- skips unresolved environment-variable path markers
- merges only managed keys for INI, YAML, and TOML
- creates parent directories before writing
- writes only when content changes
- accumulates failures and reports them at the end

Do not turn this into a full-file overwrite tool unless explicitly requested.

## Documentation Rules

When behavior changes:
- update `README.md`
- keep support claims precise
- call out limitations clearly
- separate current behavior from roadmap items

When editing templates:
- keep `Linux-Path` and `macOS-Path` markers for future Linux/macOS scripts
- do not remove non-Windows markers just because the current installer does not consume them yet

## Adding A New Package Manager

Usually the correct path is:
1. Add a new template under `templates/<manager>/`.
2. Include accurate `Windows-Path` markers.
3. Keep managed settings minimal and comments machine-readable.
4. Update `README.md` support and usage notes if needed.

Prefer marker-only template comments over human-readable prose.

If a new template shape cannot be merged by the current script, document the limitation and extend the merge logic deliberately rather than adding a brittle one-off.
