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
| `gate` | v0.9.0+ (the `diff` subcommand) |
| `comment` | v1.1.0+ (`remote pr`) |
| `guard` | **v1.10.0+** (`commitbrief guard`) |

The action installs the CLI with `go install` at the version you pin (see
`version` below).

## Quick start

Add a workflow to the consuming repo, e.g. `.github/workflows/commitbrief.yml`:

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
          # mode: comment            # default
          # request-changes-on: high # default: critical
```

Gate mode (pass/fail only, no comments, no `pull-requests: write` needed):

```yaml
      - uses: CommitBrief/commitbrief-action@v1
        with:
          provider: openai
          api-key: ${{ secrets.OPENAI_API_KEY }}
          mode: gate
          fail-on: high
```

Guard mode (declarative policy gate, no comments, no `pull-requests: write`
needed — requires CLI v1.10.0+):

```yaml
      - uses: CommitBrief/commitbrief-action@v1
        with:
          provider: anthropic
          api-key: ${{ secrets.ANTHROPIC_API_KEY }}
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
| `request-changes-on` | `""` | comment mode: severity at/above which the verdict is request-changes. Empty = never request changes (approve/comment only). This matches CLI v1.5.0+ behavior; earlier versions of this action forced `critical`. |
| `fail-on` | `high` | gate mode: fail the job if a finding meets/exceeds this severity. |
| `policy` | `.commitbrief/policy.yml` | guard mode: path to the policy file, relative to the repo root. |
| `version` | `latest` | commitbrief version to install (`go install` ref, e.g. `v1.13.0`). |

## Permissions

- **comment mode** needs `permissions: pull-requests: write` — the action
  uses the workflow's `GITHUB_TOKEN` (via `gh`) to post the review.
- **gate mode** and **guard mode** only need `contents: read`.

## Notes

- The provider's structured-output support determines review quality;
  weaker models degrade to plain text (handled gracefully). CLI-tool
  providers (`claude-cli` / `gemini-cli`) are **not** usable here — they
  need a local authenticated CLI, which isn't available in CI.
- Pin `version:` to a released tag for reproducible CI; `latest` tracks the
  newest release.
- License: GPL-3.0-or-later — see [`LICENSE`](LICENSE).
