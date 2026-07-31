# Closient fork notes

Fork of [github-aws-runners/terraform-aws-github-runner](https://github.com/github-aws-runners/terraform-aws-github-runner).
Fork discipline: minimal diff, keep `main` synced to upstream, carry patches on release-based branches until upstreamed.

## Active divergence

### `closient/v7.10.0-idle-confirmation` (base: `v7.10.0`) — scale-down idle confirmation window

GitHub's runner `busy` flag can be stale: it reads `false` for runners actively executing a
job, both shortly after job assignment (observed 25–60s lag) and deep into a running job
(observed 12+ minutes). scale-down trusts a single `busy: false` reading and terminates
mid-job runners — upstream issue
[#5085](https://github.com/github-aws-runners/terraform-aws-github-runner/issues/5085),
Closient incident C-4227 (14/14 killed instances traced to normal-path `Busy: false`
terminations while jobs were running).

The patch adds `SCALE_DOWN_IDLE_CONFIRMATION_SECONDS` (TF var
`scale_down_idle_confirmation_seconds`, default 0 = upstream behaviour): on a not-busy
reading, scale-down tags the instance `ghr:idle_detected_at` and defers; it terminates only
when not-busy readings span the window; any busy reading clears the tag. Also adds a
per-invocation census log line.

Consumed by the Closient monorepo as release `v7.10.0-closient.1` (patched `runners.zip`
asset + module source ref).

**Upstream status: to be PR'd against `main` referencing #5085 once verified in production.**

### `closient/v7.10.0-segment-unbound` (base: `v7.10.0-closient.1`) — SEGMENT unbound under `set -u`

`modules/runners/templates/start-runner.sh` assigns `SEGMENT` **only inside the X-Ray
branch** (`if [[ "$enable_xray" ... ]]`, line 191) but consumes it **unconditionally** at
line 263 (`create_xray_success_segment "$SEGMENT"`) and in the `error_handler` trap
(line 98). With X-Ray tracing disabled — the default, and Closient's configuration —
`SEGMENT` is never assigned.

That is harmless while user-data runs without `set -u`. It becomes fatal the moment
anything enables `-u` earlier in the same shell, because user-data is one concatenated
script: `$${post_install}` is spliced inline at `modules/runners/templates/user-data.sh:63`.
Closient hit exactly that (incident C-4437): a post-install hook opening with
`set -euo pipefail` leaked `-u` into this script, so `$SEGMENT` aborted user-data *after*
the runner had registered with GitHub but *before* its listener started. Runners appeared
healthy in the GitHub UI, claimed no jobs, and were reaped as idle ~15 min later while the
scaler launched identically-broken replacements. All `closient-large` jobs — every deploy —
were unrunnable for ~19h.

Observed on the instance console:

```
√ Runner successfully added
Tagging instance with GitHub runner agent ID: 49534
/var/lib/cloud/instance/scripts/part-001: line 703: SEGMENT: unbound variable
ERROR: runner-start-failed with exit code 1 occurred on 1
FAILED Failed to start cloud-final.service - Cloud-init: Final Stage.
```

The patch is `"$${SEGMENT:-}"` at both call sites — note the `$$`. **`start-runner.sh` is
itself rendered through `templatefile()`**, so a bare `$${...}` would be parsed as a
Terraform interpolation and fail the plan with *"Extra characters after interpolation
expression; Template interpolation doesn't expect a colon at this location"*. The original
`"$SEGMENT"` survived only because a brace-less `$NAME` is not an interpolation. Existing
precedent in the same file: `$${extra_flags}` and `$${config}` (lines 257, 269). This restores the script's own intent
rather than changing behaviour: `create_xray_success_segment` and
`create_xray_error_segment` already open with

```bash
local SEGMENT_DOC="$1"
if [ -z "$SEGMENT_DOC" ]; then
  echo "No segment doc provided"
  return
fi
```

so they were written to tolerate an absent segment — the call sites simply never expressed
it in a `-u`-safe way. Line 192's `echo "$SEGMENT"` is left alone: it sits inside the
branch that just assigned it.

Consumed by the Closient monorepo as release `v7.10.0-closient.2`. The `runners.zip` asset
is byte-identical to `v7.10.0-closient.1` — this patch touches only a rendered template, no
Lambda code.

**Upstream status: PR'd as
[github-aws-runners/terraform-aws-github-runner#5233](https://github.com/github-aws-runners/terraform-aws-github-runner/pull/5233)
(branch `fix/segment-unbound-under-set-u`, cut clean off upstream `main` so it carries only
this fix, not the idle-confirmation patch). Retire this divergence once it merges. Affects
any consumer running with tracing disabled and `set -u` anywhere in user-data, so it is not
Closient-specific.**

## Historical (superseded)

* `closient-diagnostics` — C-2580 diagnostic logging in scale-down + C-2619
  `source_code_hash` fixes; retired when C-2773/C-3211 moved runners to on-demand and
  v7.10.0 shipped `termination-watcher` as a release asset.
* Merged upstream: PR #5055 (termination-watcher deregistration), #5056 (JWT `jti` claim),
  #5088 (drop aws-sdk v2 dependency).
