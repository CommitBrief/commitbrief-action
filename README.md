# CommitBrief Review — GitHub Action

Run [CommitBrief](https://github.com/CommitBrief/commitbrief) — LLM code
review for git diffs — on your pull requests in CI. Three modes:

- **`comment`** (default) — posts each finding as an inline review comment
  and submits a verdict (approve / comment / request-changes) via
  `commitbrief remote pr`.
- **`gate`** — runs `commitbrief diff <base>...<head> --fail-on=<sev>` and
  fails the job when a finding meets/exceeds the threshold. No comments.
- **`guard`** — runs `commitbrief guard --diff <base>...<head> --policy
  <path>` and fails the job when the declarative policy
  (`.commitbrief/policy.yml`) is breached. No comments.

Minimum CLI version by mode:

| mode | needs CLI |
|------|-----------|
| `gate` | Requires v0.9.0 or later (the `diff` subcommand) |
| `comment` | Requires v1.1.0 or later (`remote pr`) |
| `guard` | **Requires v1.10.0 or later** (`commitbrief guard`) |

The action installs the prebuilt CLI binary from the matching GitHub
release and verifies its SHA-256 against that release's `checksums.txt`
before putting it on `PATH`, so there is no Go toolchain setup and no
compile step. A download or checksum failure fails the job; it never falls
back to a source build. The check proves integrity (the archive is exactly
the one the release lists), not provenance: `checksums.txt` is unsigned and
comes from the same release. Linux, macOS and Windows runners on x64 or
ARM64 are covered; any other runner, or a `version` that is a branch or
commit SHA, builds from source with `go install` and logs a warning.

## Quick start

Add a workflow to the consuming repo, e.g. `.github/workflows/commitbrief.yml`.
`version` defaults to the CLI release this action tag was cut against, so
`@v1` alone is reproducible between action updates. Pin it explicitly when
you want to control upgrades yourself:

```yaml
name: CommitBrief
on:
  pull_request:

permissions:
  contents: read
  pull-requests: write   # comment mode posts the review

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: CommitBrief/commitbrief-action@v1
        with:
          provider: anthropic
          api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          version: v1.18.0
          # mode: comment            # default
          # request-changes-on: high # default: "" (never request changes)
```

Gate mode (pass/fail only, no comments, no `pull-requests: write` needed):

```yaml
      - uses: CommitBrief/commitbrief-action@v1
        with:
          provider: openai
          api-key: ${{ secrets.OPENAI_API_KEY }}
          version: v1.18.0
          mode: gate
          fail-on: high
```

Guard mode (declarative policy gate, no comments, no `pull-requests: write`
needed — Requires CLI v1.10.0 or later):

```yaml
      - uses: CommitBrief/commitbrief-action@v1
        with:
          provider: anthropic
          api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          version: v1.18.0
          mode: guard
          policy: .commitbrief/policy.yml   # default; commit this file to the repo
```

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `provider` | — (required) | `anthropic` \| `openai` \| `gemini` \| `deepseek` \| `mistral` \| `cohere` \| `ollama`. |
| `api-key` | `""` | Provider API key — pass a repository secret. Not needed for `ollama`. |
| `model` | `""` | Model override; defaults to the provider's default. |
| `mode` | `comment` | `comment` (inline comments + verdict), `gate` (exit-code gate), or `guard` (declarative policy gate). |
| `request-changes-on` | `""` | comment mode: severity at/above which the verdict is request-changes. Requires CLI v1.5.0 or later to leave this empty (never request changes — approve/comment only); earlier versions of this action defaulted this input to `critical` instead. |
| `fail-on` | `high` | gate mode: fail the job if a finding meets/exceeds this severity. |
| `policy` | `.commitbrief/policy.yml` | guard mode: path to the policy file, relative to the repo root. |
| `version` | current release tag | commitbrief version to install, e.g. `v1.18.0`. A release tag installs the checksum-verified prebuilt binary; `latest` resolves to the newest stable release on every run; a branch or commit SHA builds from source with `go install`. |

## Permissions

- **comment mode** needs `permissions: pull-requests: write` — the action
  uses the workflow's `GITHUB_TOKEN` (via `gh`) to post the review.
- **gate mode** and **guard mode** only need `contents: read`.

## Notes

- The provider's structured-output support determines review quality;
  weaker models degrade to plain text (handled gracefully). CLI-tool
  providers (`claude-cli` / `gemini-cli`) are **not** usable here — they
  need a local authenticated CLI, which isn't available in CI.
- The default `version` moves only when the `v1` tag of this action moves.
  `latest` asks the GitHub releases API on every run and can change the CLI
  between two runs of the same workflow; use it only if you want that.
- License: GPL-3.0-or-later — see [`LICENSE`](LICENSE).
