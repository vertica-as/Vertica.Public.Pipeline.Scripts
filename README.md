# SSC Global Configs

Template-driven global package manager configuration for Windows.

This repository keeps a small set of opinionated default configs for multiple package managers in one place, then syncs those settings into the correct per-user or machine-wide config files on a Windows machine.

Current focus:
- Windows only
- Global config sync, not package manager installation
- Safe merging of managed settings into existing config files

Important repository rule:
- keep the Linux and macOS path markers in templates, even though the current script only syncs Windows targets

## What This Repository Does

`install-windows-configs.ps1` walks the `templates/` directory, discovers each config template automatically, reads the `Windows-Path` markers embedded in the template comments, and writes the managed settings to those destinations.

When the script is run as a standalone downloaded file and no local `templates/` directory is present next to it, it can also download the template files directly from this GitHub repository.

The script is designed to be conservative:
- It creates missing parent directories.
- It updates only the keys managed by the template.
- It preserves unrelated user settings whenever possible.
- It writes files only when content actually changed.
- It reports all write failures at the end instead of stopping on the first one.

This makes the repo useful as a central source of default package manager policy across a Windows workstation.

## What It Does Not Do

- It does not install `npm`, `pnpm`, `yarn`, `bun`, `uv`, or any other package manager.
- It does not yet apply Linux, WSL, or macOS configs.
- It does not currently manage nested YAML structures; YAML templates are expected to use top-level keys only.
- It does not try to own the entire target config file.

## Supported Package Managers

The repository currently ships templates for:

| Manager | Covers | Template | Windows target(s) |
| --- | --- | --- | --- |
| npm | `npm`, `npx` | `templates/npm/.npmrc` | `%USERPROFILE%\.npmrc`, `%APPDATA%\npm\etc\npmrc` |
| pnpm | `pnpm`, `pnpx` | `templates/pnpm/config.yaml` | `%LOCALAPPDATA%\pnpm\config\config.yaml`, `%LOCALAPPDATA%\pnpm\config\rc`, `%XDG_CONFIG_HOME%\pnpm\config.yaml`, `%XDG_CONFIG_HOME%\pnpm\rc` |
| Yarn | Yarn 2+/Berry | `templates/yarn/.yarnrc.yml` | `%USERPROFILE%\.yarnrc.yml` |
| Bun | `bun`, `bunx` | `templates/bun/.bunfig.toml` | `%USERPROFILE%\.bunfig.toml`, `%XDG_CONFIG_HOME%\.bunfig.toml` |
| uv | `uv`, `uvx` | `templates/uv/uv.toml` | `%APPDATA%\uv\uv.toml`, `%PROGRAMDATA%\uv\uv.toml` |

The current templates mainly enforce supply-chain hardening defaults such as:
- delaying very new package releases
- disabling install scripts where the package manager supports it
- blocking source builds where that is the closest equivalent control

## Windows Coverage Notes

- `npm`: covers both user config and global/prefix config on Windows
- `pnpm`: covers both the YAML global config and legacy/global `rc`, including XDG-driven Windows locations when `XDG_CONFIG_HOME` is set
- `yarn`: covers the home-level Yarn Berry config
- `bun`: covers the home config plus the XDG-driven global config location when `XDG_CONFIG_HOME` is set
- `uv`: covers both user-level and system-level config files on Windows

Some targets may require elevation:
- `%PROGRAMDATA%\uv\uv.toml`
- other machine-level config paths, depending on how the package manager was installed and which directories are writable on that workstation

If a `Windows-Path` marker depends on an environment variable that is not set, the script skips that target instead of writing to a literal unresolved path. Those optional skipped targets stay quiet during normal runs and only appear with verbose output.

## How It Works

The script supports three config shapes:
- INI-style key/value files such as `.npmrc` and legacy `pnpm` `rc`
- top-level YAML key/value files such as `pnpm` `config.yaml` and `.yarnrc.yml`
- TOML files such as `.bunfig.toml` and `uv.toml`

High-level flow:
1. Discover every template file under `templates/`.
2. Read `Windows-Path` markers from each template.
3. Expand environment variables such as `%USERPROFILE%`.
4. Merge template-managed settings into the destination config.
5. Write the result only if it changed.

The current script only reads `Windows-Path` entries.

## Usage

Run from the repository root in Windows PowerShell or PowerShell 7:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-windows-configs.ps1
```

Or:

```powershell
pwsh -File .\install-windows-configs.ps1
```

Standalone GitHub execution also works:

```powershell
curl.exe -L "https://raw.githubusercontent.com/vertica-as/Vertica.Public.Pipeline.Scripts/refs/heads/main/install-windows-configs.ps1" -o "$env:TEMP\install-windows-configs.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-windows-configs.ps1"
```

In that mode, the script downloads the template files listed in `template-files.txt` from the same GitHub repository, applies them, and then removes the temporary downloaded templates.

Typical output looks like this:

```text
[npm] UPDATED: C:\Users\you\.npmrc
[yarn] UNCHANGED: C:\Users\you\.yarnrc.yml
All Windows config files are in sync with the templates.
```

If a destination cannot be written, the script keeps going and throws a combined error at the end.

## Repository Layout

```text
.
|-- install-windows-configs.ps1
|-- template-files.txt
`-- templates/
    |-- bun/
    |-- npm/
    |-- pnpm/
    |-- uv/
    `-- yarn/
```

Each template file contains only the machine-readable path markers the script parses, using the format `<Platform>-Path: <path>`.

Examples:
- `Windows-Path: %USERPROFILE%\.npmrc`
- `Linux-Path: ~/.config/uv/uv.toml`
- `macOS-Path: ~/.yarnrc.yml`

## Authoring Rules For Templates

When adding or changing a template:
- Keep path markers in comments using the exact format `<Platform>-Path: <path>`.
- Use `Windows-Path` for any path the current script should manage.
- Keep YAML templates flat unless the merge logic is extended.
- Prefer a minimal set of managed settings.
- Avoid extra human-readable comments unless the script needs them.

In most cases, adding a new package manager should only require a new template file. The script already discovers templates automatically.

## Current Constraints

- Windows is the only implemented platform.
- YAML merging only handles top-level keys.
- Dynamic custom config locations that depend on package-manager-specific runtime settings are not auto-discovered.
- There is no dry-run mode yet.
- There is no automated test suite yet.

## Roadmap

Planned next steps:
- add Linux support by reading `Linux-Path` markers
- add macOS support by reading `macOS-Path` markers
- add WSL support with a clear model for targeting Linux config paths from Windows
- add a dry-run or preview mode
- add a way to target a single package manager or template
- add tests for merge behavior across INI, YAML, and TOML fixtures
- document a recommended baseline policy for each supported package manager

## Contributing

Good changes in this repository are usually small and explicit.

When contributing:
- preserve the non-destructive merge behavior
- avoid hardcoding template lists when template discovery already works
- keep documentation aligned with actual script behavior
- do not claim cross-platform support until the automation exists
- do not delete Linux or macOS path markers from templates just because the current script is Windows-only

## AI Contributor Notes

If you are using an AI coding agent in this repository:
- treat this as a Windows-first config sync tool
- do not describe it as a package manager installer
- prefer updating templates over adding script special cases
- preserve user-owned settings in destination files
- update `README.md` when supported managers or behavior change
- preserve `Linux-Path` and `macOS-Path` markers for future platform scripts
