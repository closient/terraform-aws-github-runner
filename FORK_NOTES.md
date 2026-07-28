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

## Historical (superseded)

* `closient-diagnostics` — C-2580 diagnostic logging in scale-down + C-2619
  `source_code_hash` fixes; retired when C-2773/C-3211 moved runners to on-demand and
  v7.10.0 shipped `termination-watcher` as a release asset.
* Merged upstream: PR #5055 (termination-watcher deregistration), #5056 (JWT `jti` claim),
  #5088 (drop aws-sdk v2 dependency).
