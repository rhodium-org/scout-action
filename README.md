# scout-action

Composite GitHub Action that runs [scout](https://scout.downloadserver.co.uk)
gap-analysis against your repo's specs and posts the findings as a PR
comment.

Tracks [`rhodium-org/scout#28`](https://github.com/rhodium-org/scout/issues/28)
for the design rationale (strictness presets, determinism risk, cost
controls). The Service API surface it consumes is documented in scout's
[`docs/05-api.md`](https://github.com/rhodium-org/scout/blob/main/docs/05-api.md)
§ "Service API (`scout-api.downloadserver.co.uk`)".

## Quickstart

```yaml
# .github/workflows/scout.yml in the consuming repo
name: scout
on: [pull_request]

jobs:
  scout:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write   # for the findings comment
    steps:
      - uses: actions/checkout@v4
      - uses: rhodium-org/scout-action@v1
        with:
          api-key: ${{ secrets.SCOUT_API_KEY }}
          requirements-glob: 'docs/specs/requirements/**/*.md'
          nfrs-glob: 'docs/specs/nfrs/**/*.md'
          tests-glob: 'docs/specs/tests/**/*.md'
          docs-glob: 'README.md docs/architecture/**/*.md'
          # strictness: report-only  (default — never fails the step)
```

The default `strictness: report-only` always passes the step regardless
of findings. The PR comment lands either way. Opt into stricter gating
once your team trusts scout's output on your corpus (see
[Strictness modes](#strictness-modes) below).

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `api-key` | yes | — | Bearer; conventionally `${{ secrets.SCOUT_API_KEY }}`. |
| `endpoint` | no | `https://scout-api.downloadserver.co.uk` | Override for local / staging scout. |
| `system-name` | no | repo name from `$GITHUB_REPOSITORY` | LLM orientation. |
| `requirements-glob` | no | — | Files become `type: requirement` items. |
| `nfrs-glob` | no | — | `type: nfr`. |
| `tests-glob` | no | — | `type: test`. |
| `docs-glob` | no | — | `type: doc` (catch-all / context). |
| `max-input-bytes` | no | `1000000` | Hard cap on total bytes shipped per call (cost control). |
| `max-file-bytes` | no | `200000` | Per-file cap; oversize files truncate with a marker. |
| `strictness` | no | `report-only` | See [Strictness modes](#strictness-modes). |
| `max-high` | no | unlimited | Per-severity count cap; overrides `strictness`. |
| `max-medium` | no | unlimited | Per-severity count cap; overrides `strictness`. |
| `max-low` | no | unlimited | Per-severity count cap; overrides `strictness`. |
| `fail-on-upstream-error` | no | `false` | If scout / its LLM returns 5xx, fail the step (default: warn + pass). |
| `comment-on-pr` | no | `true` | Post the findings summary as a PR comment. |
| `comment-mode` | no | `update` | `update` (one rolling comment per PR) or `append` (one per run). |
| `model_guid` | no | scout's default | LiteLLM model alias; what's available depends on your scout account. |
| `temperature` | no | scout's default (currently 0.2) | 0.0 = deterministic; ≥0.5 not recommended for CI. |
| `github-token` | no | `${{ github.token }}` | Token used to post the PR comment. |

## Outputs

| Output | Notes |
|---|---|
| `execution-id` | Scout's numeric execution id. Deep-link: `https://scout.downloadserver.co.uk/#/history/<execution-id>`. |
| `findings-count` | Total findings across all severities. |
| `max-severity` | `high` \| `medium` \| `low` \| `none`. |
| `findings-json-path` | Path on the runner to the raw findings JSON (good for `actions/upload-artifact`). |

> **Naming note.** Issue scout#28 originally proposed `execution-guid`,
> but scout's bearer API surfaces a stable numeric id (`executionId`)
> rather than a GUID. The output is named `execution-id` to match what
> scout actually returns and what powers the deep-link URL.

## Strictness modes

`strictness` is a discrete preset that translates into per-severity
thresholds. Per-severity inputs always win if both are specified — so
`strictness: block-on-any-high` + `max-high: 3` means "up to 3 high
findings is OK".

| Mode | Equivalent thresholds | Behaviour |
|---|---|---|
| `report-only` (default) | all unlimited | Always passes; always comments. **Safe shipping default.** |
| `block-on-any-high` | `max-high: 0` | Fails if ≥1 high; medium / low ignored. |
| `block-on-high-medium` | `max-high: 0`, `max-medium: 0` | High or medium fails the step. |
| `strict` | `max-high: 0`, `max-medium: 0`, `max-low: 0` | Any finding fails the step. |
| `custom` | (use explicit per-severity inputs) | Roll your own caps. |

`report-only` is the default — and not `block-on-any-high` — because
scout's default `temperature=0.2` means re-running the same input can
produce a new "high" finding the second time and break the merge button.
Teams opt into stricter modes once they trust scout's output on their
corpus. Tighten `temperature: 0` if you want maximum determinism before
stepping up the strictness.

## Auth — minting & rotating the bearer key

1. **Mint** a key from scout's Admin tab → "Service API keys" with
   `label = <repo-name>` (e.g. `cluster`, `whisper-gpu`,
   `shared-audit`). Scout returns the plaintext key once.
2. **Store** as a repo secret named `SCOUT_API_KEY` (or an org-level
   secret for fleet rollout). The action reads it via the `api-key`
   input.
3. **Rotate** by revoking the old key in scout's Admin tab → minting a
   new one → updating the repo / org secret. **No action code change
   needed** — the action just reads whatever the secret holds.

One key per consuming repo so revoke is targeted.

## PR comment format

```markdown
## 🔍 scout findings (execution #47)

| Severity | Count |
|---|---|
| high   | 2 ⚠️ |
| medium | 5 |
| low    | 12 |

Model: `claude-openai-proxy/claude-haiku-4-5` — strictness: `block-on-any-high`

### ⚠️ High (2)

- **No coverage for SSO-IDP outage** (missing_test) — REQ-1 specifies SSO login but TST-1 only covers happy path.
- …

### Medium (5)

<details><summary>5 medium finding(s)</summary>
…
</details>

[View full run in scout →](https://scout.downloadserver.co.uk/#/history/47)
```

`comment-mode: update` finds the previous scout comment by the
`<!-- scout-action -->` magic marker and edits in place, keeping PR
conversations clean across many runs.

The action needs `permissions: pull-requests: write` on the job (or the
default `${{ github.token }}` won't be able to post). For cross-repo
comments, pass a PAT via `github-token`.

## Cost control

Scout's per-analyse cost depends on input size, output size, and the
configured model. The current reference (Opus 4.8, 50 KB of docs) is
**~\$0.51 per call** at public Anthropic API rates — see scout's
[`CLAUDE.md`](https://github.com/rhodium-org/scout/blob/main/CLAUDE.md)
§ "Analyse cost reference" for the breakdown.

This action enforces two caps to keep spend bounded:

- `max-input-bytes` — hard cap on total bytes shipped per call (default
  ~1 MB). Files are gathered in `requirements → nfrs → tests → docs`
  order; once the budget is exhausted, remaining files are dropped
  (with a `::warning::` line so you can see what was skipped).
- `max-file-bytes` — per-file cap (default 200 KB). Oversize files are
  truncated with a `... [truncated at N bytes]` marker so the model
  knows it's not the whole picture.

For tighter spend control, scope your globs with the workflow-level
`paths:` filter so the action only fires on PRs that touch
specification files. The action does not try to be clever about diffs
in v1 (see [Out of scope](#out-of-scope) below).

## Outputs example

```yaml
- name: scout
  id: scout
  uses: rhodium-org/scout-action@v1
  with: { api-key: ${{ secrets.SCOUT_API_KEY }}, requirements-glob: 'docs/**/*.md' }

- name: Archive findings
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: scout-findings
    path: ${{ steps.scout.outputs.findings-json-path }}

- name: Echo
  run: |
    echo "execution-id=${{ steps.scout.outputs.execution-id }}"
    echo "findings-count=${{ steps.scout.outputs.findings-count }}"
    echo "max-severity=${{ steps.scout.outputs.max-severity }}"
```

## Local testing

The runtime script is plain bash. To dry-run against a real scout
instance from your laptop:

```bash
export SCOUT_API_KEY='sk_...'
export GITHUB_REPOSITORY='rhodium-org/scout-action'
export SCOUT_REQUIREMENTS_GLOB='docs/specs/**/*.md'
# ... etc; see scripts/run.sh for the full SCOUT_* list
bash scripts/run.sh
```

The script writes outputs to `$GITHUB_OUTPUT` when set; if you don't
set it, outputs go nowhere (no-op).

## Versioning

- `@v1` — moving major tag, advances with each minor / patch.
- `@v1.0.0` etc — immutable, pin if you want lockstep behaviour.

Following the rest of the workspace, no floating `@main` references in
production workflows.

## Out of scope (V2)

- **Forgejo Actions equivalent.** Same shape, different action runner;
  file when there's a Forgejo-hosted consumer that wants the gate.
- **Per-finding suppression (`.scoutignore`).** Requires stable finding
  ids across runs, which scout doesn't have today.
- **Cross-PR diff** ("only show NEW findings vs base branch"). Requires
  caching the base-branch scout run.
- **Auto-fix suggestions.** Scout is a finder, not a writer.

## License

See [`LICENSE`](LICENSE) — this is operator-owned tooling for
`rhodium-org`; license follows whatever the org default is.
