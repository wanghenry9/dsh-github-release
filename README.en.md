# dsh-github-release

> A **gated** GitHub release skill for [DeepSeek Harness](https://github.com/) (DSH):
> one sentence tells the agent to package a local project to spec, scan it for secrets,
> generate bilingual READMEs, then push it to GitHub with a semantic-version tag.

The skill name (from the `SKILL.md` frontmatter) is **`github-release`**; the repository is
**`dsh-github-release`**. It must be installed into a directory named `github-release`,
otherwise DSH will not load it.

---

## What it does

Say *"push this project to GitHub"* about any project, and the agent loads this skill and walks
the gated workflow below. **Every gate can block the push — that is deliberate**: it is better to
stop and ask than to publish a secret or a pile of junk to a public repo.

| Step | What happens | Gate |
| --- | --- | --- |
| 1 | Locate the project root + read credentials (masked probe, never echoes the token) | Missing credentials → stop |
| 2 | Ask "create a new repo or reuse an existing one?" + visibility | Always asked, never guessed |
| 3 | Ask "project name / project type / one-line positioning" | Always asked, never guessed |
| 4 | **Secret scan** (blocking) + **packaging compliance check** | BLOCKER → stop |
| 5 | Compute the semantic version and confirm the tag (first release `v0.1.0`) | Never tags silently |
| 6 | Generate `README.md` + `README.en.md` + `.gitignore` / `.gitattributes` | Copy confirmed first |
| 7 | `commit` / `push` / tag, each confirmed separately | One approval per action |
| 8 | Deliver the repo link, tag, commit and a project blurb | — |

## Features

- **Blocking secret scan** — GitHub / OpenAI / AWS / Google / Slack / Stripe / npm / PyPI /
  HuggingFace tokens, PEM private keys, credentialed connection strings, bearer tokens,
  password assignments, internal IPs. A hit exits with code `3` and reports only
  `file:line` plus a masked fragment — **it never pastes a secret into the conversation**.
- **Packaging compliance check** — `.gitignore` coverage, >100 MB files (hard block),
  accidental `node_modules` / `dist` commits, archives and executables, large objects in
  history, missing LICENSE / `.gitattributes`, unset git identity.
- **Zero token persistence** — the token is read from `~/.dsh/secrets/github.env` and fed to
  git's shell-form credential helper **through a process environment variable only**. It is
  never written to the remote URL, `.git/config`, or a log.
- **No `gh` CLI required** — repositories are created straight through the GitHub REST API.
- **Sandbox-aware** — the scripts follow a "declare → execute once at top level → consume"
  pattern so scans, checks, document generation and `add` / `commit` / `tag` all work under
  the DSH `workspace-write` sandbox.

## Requirements

| Item | Requirement |
| --- | --- |
| OS | **Windows** (the scripts wrap child processes with `cmd.exe` and evaluate `%ERRORLEVEL%`) |
| PowerShell | **PowerShell 7+** (`pwsh`) |
| Git | Any recent version, on `PATH` |
| Third-party modules | **None** — built-in cmdlets plus `git` only |
| `gh` CLI | **Not required** |
| Credentials | A GitHub PAT (fine-grained or classic) |

## Installation

This repository is the skill's **source directory** (version-controllable and re-installable).
DSH loads skills from a user-level skill root, so copy it in under the name `github-release`:

```powershell
git clone https://github.com/wanghenry9/dsh-github-release.git
$src = Join-Path (Get-Location) 'dsh-github-release'
$dst = Join-Path $env:DSH_HOME 'skills\github-release'   # defaults to C:\Users\<you>\.dsh\skills\github-release

New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item (Join-Path $src 'SKILL.md') $dst -Force
Copy-Item (Join-Path $src 'scripts')    $dst -Recurse -Force
Copy-Item (Join-Path $src 'assets')     $dst -Recurse -Force
Copy-Item (Join-Path $src 'references') $dst -Recurse -Force
```

DSH watches the skill directory, so the change takes effect immediately — **no restart needed**.

> The skill lives in `$DSH_HOME/skills/` (the user-level skill root) rather than inside the DSH
> installation, so upgrading `dsh` will not overwrite it.

## Credentials

Put your PAT into `$env:DSH_HOME\secrets\github.env` (template: `assets/github-env.template`):

```ini
GITHUB_TOKEN=your-token
GITHUB_USERNAME=your-github-username
GITHUB_EMAIL=your-github-email-or-noreply-address
```

A **fine-grained token** is recommended
(<https://github.com/settings/personal-access-tokens/new>):

| Permission | Value | Purpose |
| --- | --- | --- |
| `Contents` | Read and write | Push code / create tags / create releases |
| `Metadata` | Read-only | Pulled in automatically with `Contents` |
| `Administration` | Read and write | Only if you want the skill to **create repositories** |

For a classic token, ticking `repo` is enough.

**Lookup order** (first match wins): the `GITHUB_TOKEN` environment variable →
`<project root>\.git-secrets.local` → `<project root>\github.env` →
`$env:DSH_HOME\secrets\github.env`.

Verify with the probe (prints a mask only, never the plaintext token):

```powershell
pwsh -NoProfile -File "$env:DSH_HOME\skills\github-release\scripts\github-credentials.ps1" -Check
```

## Quick start

Once installed and configured, just tell the agent:

```
push this project to GitHub
```

Or name the skill explicitly: *"use github-release to package and upload this"*.

## Layout

```
SKILL.md                         Main skill document (workflow, iron rules, troubleshooting)
README.md                        Chinese
README.en.md                     This file
LICENSE                          MIT
scripts/
  github-credentials.ps1         Credential reader and masked probe (Get-GitHubCredentials)
  github-git.ps1                 External-command capture helper for restricted sandboxes
  github-repo-check.ps1          Packaging compliance check
  github-secret-scan.ps1         Secret scan (blocking)
  github-repo-create.ps1         Token probe / repo lookup / repo creation (REST API)
assets/
  github-env.template            Credential file template
references/
  secret-scan-rules.md           Scan rules, exceptions and known blind spots
  release-checklist.md           Pre-release checklist
```

## Script reference

All four scripts are usable standalone from the command line.

### `github-credentials.ps1`

```powershell
pwsh -File github-credentials.ps1 -Check          # prints OK / MISSING only
pwsh -File github-credentials.ps1                 # prints the masked token and other fields
pwsh -File github-credentials.ps1 -NoMask         # emits a plaintext token line (consume safely, never print)
```

It can also be dot-sourced: `. github-credentials.ps1` then
`Get-GitHubCredentials -RepoPath <path>`.

### `github-repo-check.ps1` — packaging compliance

```powershell
pwsh -File github-repo-check.ps1 -ProjectPath <root> -ReportPath <report>
pwsh -File github-repo-check.ps1 -ProjectPath <root> -StagedOnly   # staged files only
```

Switches: `-Json` / `-StagedOnly` / `-WarnFileMB 50` / `-BlockFileMB 100`.
**Exit code `3` = a BLOCKER was found.**

### `github-secret-scan.ps1` — secret scan

```powershell
pwsh -File github-secret-scan.ps1 -ProjectPath <root> -ReportPath <report>
pwsh -File github-secret-scan.ps1 -ProjectPath <root> -StagedOnly
pwsh -File github-secret-scan.ps1 -ProjectPath <root> -Ignore 'docs/sample.md','tests\*'
```

Switches: `-Json` / `-StagedOnly` / `-NoMask` / `-MaxHits 400` / `-MaxFileMB 4` /
`-Ignore <pattern,pattern>`. **Exit code `3` = a BLOCKER was hit.**

> `-Ignore` is only for false positives the user has confirmed.
> **Never edit the scan rules themselves to let something through.**

### `github-repo-create.ps1` — create a repository (REST API)

```powershell
pwsh -File github-repo-create.ps1 -Probe                                  # validate the token
pwsh -File github-repo-create.ps1 -Status -Name <repo>                    # exists → 0, missing → 4
pwsh -File github-repo-create.ps1 -Create -Name <repo> -Visibility private `
     -Description "one-line summary" -NoAutoInit
```

**You must pass `-NoAutoInit` when pushing an existing local project.** Without it GitHub
defaults to `auto_init=true` and creates an initial README commit, so the remote ends up with
history the local repo does not have and the push is rejected:

```
! [rejected]  main -> main (fetch first)
```

Exit codes: `0` success / `2` credentials missing / `3` API failure or insufficient permission /
`4` repository not found.

## Security design

- **The token is read only from the credential file** and handed to git's shell-form credential
  helper through a process environment variable:
  ```powershell
  git config credential.helper '!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$GITHUB_TOKEN"; }; f'
  ```
  The username can simply be `x-access-token` (GitHub does not validate it) — **the token goes in
  the password slot**. Remove it right after with `Remove-Item Env:\GITHUB_TOKEN`.
- **Credential files never reach the index**: `.git-secrets.local` / `github.env` / `secrets/`
  are covered by `.gitignore`, and both `github-repo-check.ps1` and the credential probe verify
  they are not tracked by git.
- **A BLOCKER stops the run** (`exit 3`), revealing only paths, line numbers, rule names and
  masked fragments.
- Tightening the credential file's ACL to `Administrator` / `SYSTEM` / `Administrators` is
  recommended.

## Known limitation: the DSH sandbox

Remote git operations (`push` / `pull` / `fetch` / `ls-remote`) and GitHub REST API calls
**require the sandbox to be lifted**. The sandbox forbids child processes from creating pipes,
and git must create a bidirectional pipe for its transport helper
(`git-remote-https` / `git-remote-ssh`):

```
error: cannot create standard input pipe for remote-https: Permission denied
```

REST API calls are instead stopped by the sandbox's egress proxy — when DNS resolves into the
reserved range `198.18.0.0/15` (common with Clash fake-IP) the TLS handshake fails:

```
REST FAIL: The SSL connection could not be established
DNS api.github.com => 198.18.0.112
```

Both are **sandbox-side effects, unrelated to your network or token**, and they disappear once
the sandbox is lifted.

**The resulting split:**

| Environment | What it can do |
| --- | --- |
| Sandboxed (`workspace-write`) | Locate the project, credential probe, secret scan, compliance check, README generation, `.gitignore` / `.gitattributes`, `git add` / `commit` / `tag` |
| Needs a one-off full-access approval | `git push`, `git push origin <tag>`, and GitHub REST API calls (repo creation / verification) |

**Do not configure `http.proxy` for git.** With TUN mode the proxy already handles system routing,
and forcing `http.proxy` can break a connection that used to work. Only investigate the proxy when
things still time out or fail TLS **after** the sandbox is lifted; see the "network and proxy"
section of `SKILL.md` for the order to check things in.

## FAQ

| Symptom | Cause | Fix |
| --- | --- | --- |
| `! [rejected] main -> main (fetch first)` | The repo was initialised by `auto_init`, so the remote already has commits | Create it with `-NoAutoInit`, or `git pull --rebase` first |
| `could not read Username` | The credential helper is not in effect, or `GITHUB_TOKEN` is missing from that process | Set the variable in the same PowerShell session before pushing |
| `403` / `Authentication failed` | Token lacks permission or has expired | Add `Contents: Read and write` to the fine-grained PAT |
| Repo creation returns `403` | Missing `Administration: Read and write`, or the org has not authorised the token | Add the permission, or create the repo by hand and use the "reuse existing" path |
| `StandardOutputEncoding is only supported when standard output is redirected` | A child process was started inside a function, which the sandbox denies | Use the `New-Capture` + `cmd.exe /c` + `Get-Capture` three-step form, at the **caller's top level** |
| `The filename, directory name, or volume label syntax is incorrect` | The `.bat` was written as ASCII, turning a CJK path into `????` | Write `.bat` files as **UTF-8 without BOM** |
| The report flags `references/secret-scan-rules.md` | That is **sample text inside the rules document**, not a leak | Expected; the skill's own script directory is excluded automatically |

More troubleshooting lives in `SKILL.md`.

## License

[MIT](LICENSE) © 2026 wanghenry9
