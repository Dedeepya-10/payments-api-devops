# Incident note — payments-api pods never ready, no traffic served

## Symptoms

- `kubectl get pods` shows 0/2 ready, with containers repeatedly restarting
  (`CrashLoopBackOff` / high restart count).
- `kubectl get endpoints payments-api` shows no addresses — the Service has
  nothing to route to.
- Any request through the Service times out or connection-refuses.

## Root causes

1. **Selector/label mismatch.** The Deployment's pod template is labelled
   `app: payments`, but `spec.selector.matchLabels` (and the Service's
   selector) expect `app: payments-api`. The Deployment itself is accepted
   by the API server, but the Service never finds a matching pod, so it has
   no endpoints regardless of pod health.
2. **Service port mismatch.** `targetPort: 80` on the Service, but the
   container listens on `8080` (per `app.py` / `PORT` default). Even with
   label matching fixed, traffic sent to the pod on port 80 would be
   refused.
3. **Wrong liveness path.** The liveness probe hits `/health`, which doesn't
   exist on this app — only `/healthz` does. Every liveness check fails,
   so kubelet kills and restarts the container indefinitely before it ever
   has a chance to pass readiness.
4. **Missing `DATABASE_URL`.** The app's `/ready` handler returns HTTP 503
   until `DATABASE_URL` is set, and the env var is absent from the
   manifest. Readiness never succeeds even on a healthy, running process.
5. **Memory limit too low.** `memory: 16Mi` is below what a Python
   interpreter plus Flask/gunicorn needs just to start, so the container is
   OOMKilled almost immediately — visible as `OOMKilled` in
   `kubectl describe pod`.
6. **Probe timing too aggressive for the CPU limit.** `initialDelaySeconds: 1`
   combined with a `50m` CPU limit means the container is CPU-throttled
   during interpreter startup and the first liveness check fires before the
   process can possibly be listening, compounding the restart loop from (3).
7. **No resource requests, `:latest` image tag, no `securityContext`.** No
   requests means the scheduler has no real signal for bin-packing or QoS
   class (pods land as `BestEffort`/`Burstable` unpredictably). `:latest`
   means a rollback or audit can't identify which build is actually running.
   The absence of a `securityContext` means the container runs as root with
   a writable root filesystem and full Linux capabilities by default.

## Fixes

See [`fixed-deployment.yaml`](fixed-deployment.yaml):

- Pod template label changed to `app: payments-api` to match the selector.
- Service `targetPort` changed to `8080`.
- Liveness probe path changed to `/healthz`, `initialDelaySeconds` raised to
  `10`.
- `DATABASE_URL` added via `secretKeyRef` (placeholder value shown; see
  `k8s/secret.example.yaml` for how this is generated for real in this repo).
- Memory limit raised to `256Mi`, CPU limit raised to `500m`, and matching
  requests (`64Mi`/`100m`) added.
- Image pinned to a commit-SHA tag instead of `:latest`.
- Added a restrictive `securityContext` (non-root, no privilege escalation,
  read-only root filesystem, all capabilities dropped) at both pod and
  container level.

## Prevention

- **CI validation before merge.** Run `kubeconform`/`kubeval` against every
  manifest in CI (this repo's [`ci.yml`](../.github/workflows/ci.yml) does
  this) so a label/selector mismatch or malformed probe fails the pipeline,
  not a live cluster.
- **A manifest linter with opinionated rules** (e.g. `kube-score` or
  `kube-linter`) to flag missing resource requests, missing
  `securityContext`, and `:latest` tags automatically — these are exactly
  the "it'll technically apply but misbehave" class of bug that slipped
  through here.
- **Require readiness/liveness probes and resource requests via policy**
  (OPA/Gatekeeper, Kyverno, or even a `kubectl apply --dry-run=server` admission
  webhook) so a Deployment missing them is rejected at admission time, not
  discovered after rollout.
- **Smoke-test the rollout in CI/CD** against a disposable kind cluster
  (`kubectl rollout status` with a short timeout) before promoting the same
  manifest to staging/production — this would have caught every issue here
  in under a minute, pre-merge.
- **Template reuse.** Generating this from a shared Helm chart/Kustomize
  base (as in `k8s/` in this repo) instead of hand-writing each Deployment
  removes the chance of typo'd labels or forgotten fields entirely.
