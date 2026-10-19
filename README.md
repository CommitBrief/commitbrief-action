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
| `gate` + `sarif-upload` | **Requires v1.19.0 or later** (`--sarif`) |
| `comment` + `since-last-review` | **Requires v1.20.0 or later** (`remote pr --since-last-review`) |

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
          version: v1.18.1
          # mode: comment            # default
          # request-changes-on: high # default: "" (never request changes)
```

Gate mode (pass/fail only, no comments, no `pull-requests: write` needed):

```yaml
      - uses: CommitBrief/commitbrief-action@v1
        with:
          provider: openai
          api-key: ${{ secrets.OPENAI_API_KEY }}
          version: v1.18.1
          mode: gate
          fail-on: high
```

Gate mode with Code Scanning upload (Requires CLI v1.19.0 or later). Instead
of printing the review to the job log, the action writes the findings as
SARIF 2.1.0 and uploads them with `github/codeql-action/upload-sarif`. They
appear as annotations and in the "Code scanning results" check on the pull
request (the action only runs on `pull_request`, so nothing is uploaded for
the default branch). The upload runs even when the gate fails the job. The
workflow needs `security-events: write` (and `actions: read` in private
repositories), and the job needs a checkout for the diff:

```yaml
permissions:
  contents: read
  security-events: write   # sarif-upload: true uploads to Code Scanning
  actions: read            # private repositories only

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
          ref: ${{ github.event.pull_request.head.sha }}   # not the merge commit: SARIF lines are head lines
      - uses: CommitBrief/commitbrief-action@v1
        with:
          provider: openai
          api-key: ${{ secrets.OPENAI_API_KEY }}
          version: v1.19.0   # sarif-upload needs CLI v1.19.0 or later
          mode: gate
          fail-on: high
          sarif-upload: true
```

Guard mode (declarative policy gate, no comments, no `pull-requests: write`
needed — Requires CLI v1.10.0 or later):

```yaml
      - uses: CommitBrief/commitbrief-action@v1
        with:
          provider: anthropic
          api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          version: v1.18.1
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
| `sarif-upload` | `false` | gate mode: `true` writes SARIF 2.1.0 to a file (instead of printing the review to the log) and uploads it to Code Scanning. Requires CLI v1.19.0 or later and `permissions: security-events: write`. Ignored with a warning in `comment` and `guard` modes. |
| `since-last-review` | `false` | comment mode: `true` reviews only the commits added since CommitBrief's last review of the pull request and falls back to a full review when that range cannot be determined safely. Requires CLI v1.20.0 or later. Ignored with a warning in `gate` and `guard` modes. |
| `version` | current release tag | commitbrief version to install, e.g. `v1.18.1`. A release tag installs the checksum-verified prebuilt binary; `latest` resolves to the newest stable release on every run; a branch or commit SHA builds from source with `go install`. |

## Permissions

- **comment mode** needs `permissions: pull-requests: write` — the action
  uses the workflow's `GITHUB_TOKEN` (via `gh`) to post the review.
- **gate mode** and **guard mode** only need `contents: read`.
- **gate mode with `sarif-upload: true`** additionally needs
  `security-events: write` (and Code Scanning available for the repository).
  Private and internal repositories also need GitHub Code Security enabled
  and `actions: read`.
  On pull requests from forks the token is read-only, so the upload fails
  there.

## Notes

- The provider's structured-output support determines review quality;
  weaker models degrade to plain text (handled gracefully). CLI-tool
  providers (`claude-cli` / `gemini-cli`) are **not** usable here — they
  need a local authenticated CLI, which isn't available in CI.
- The default `version` moves only when the `v1` tag of this action moves.
  `latest` asks the GitHub releases API on every run and can change the CLI
  between two runs of the same workflow; use it only if you want that.
- License: GPL-3.0-or-later — see [`LICENSE`](LICENSE).
