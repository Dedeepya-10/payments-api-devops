# Design questions

## 1. Secrets

In Kubernetes, secrets wouldn't be hand-created with `kubectl create secret` —
I'd run the External Secrets Operator, syncing `DATABASE_URL` and friends from
AWS Secrets Manager into a native `Secret` object per namespace, scoped by an
IAM role per environment (staging can't read production's secret). In
Terraform, the ECS task definition already references the Secrets Manager
ARN directly via `secrets` (see `terraform/modules/ecs/main.tf`), so the
plaintext value never passes through Terraform state or CI logs. Rotation:
Secrets Manager's native rotation Lambda for the database credential, on a
30-90 day schedule; ECS/EKS pick up the new value on the next task
replacement, so a rotation is paired with a rolling redeploy rather than an
in-place env change the running process won't see. CI/CD secrets (GHCR push
token, AWS OIDC role) live in GitHub's encrypted secret store and are
scoped per-environment with required reviewers on production.

## 2. Deployments

Rolling update is cheapest and already zero-downtime if probes are correct,
but a bad release is only caught after some live traffic has hit it, and
rollback means another rolling cycle. Blue-green gives instant cutover and
instant rollback by flipping a router/target group, at the cost of running
2x capacity during the switch. Canary gives the finest-grained risk control
— shift 5%, watch error rate/latency, ramp or abort — at the cost of needing
real traffic-splitting and automated analysis to be worth it. For a payments
service I'd pick **canary**: the cost of a bad release reaching 100% of
traffic (double charges, failed payments) is high enough to justify the
extra tooling, and a canary at 1-5% traffic with automatic rollback on error-
rate/latency SLO breach catches regressions before they're financially
expensive, which blue-green's binary cutover doesn't.

## 3. Observability

**Metrics:** request rate, error rate (5xx and app-level `"not ready"`),
p50/p95/p99 latency per route, pod CPU/memory vs. limits, HPA
scaling events, and `/ready` state over time. **Logs:** structured JSON
access logs (gunicorn `--access-logfile -` already emits these to stdout for
the container runtime to collect) shipped to a central store (CloudWatch
Logs / Loki) with the commit SHA tag attached for correlation. **Alerts I'd
page on:** error rate > 5% of requests for 5 minutes (users are failing
payments right now), and all pods unready simultaneously (service is fully
down). **Alerts I would not page on:** HPA scale-up events (expected,
self-healing) and a single pod restart (Kubernetes already recovers it; only
page if restarts loop repeatedly within a short window).

## 4. Incident response

**0-2 min:** Check the alert/dashboard — is it every endpoint or just one?
Pull up the deploy timeline to confirm the release 2am correlates with the
latency jump. **2-5 min:** `kubectl top pods` / CPU-memory dashboards to
rule out resource starvation (OOM/CPU throttling), and check the HPA — is it
maxed out? **5-10 min:** Compare p95 latency and error rate pre/post-deploy
on the dashboard; check recent logs for new error patterns (DB timeouts,
slow queries) that line up with the new revision. **10-15 min:** If the
release is clearly the cause and the fix isn't obvious, roll back
(`kubectl rollout undo` / redeploy the previous SHA) rather than debugging
live — restore service first, investigate the root cause after, in a
follow-up with logs/traces pulled from the bad window.

## 5. Cost

First step: CUR (Cost and Usage Report) or AWS Cost Explorer grouped by tag
(`Project`/`Environment` tags are already on every resource via
`default_tags` in Terraform) to see which service/environment grew, then
check if it's a usage increase (more traffic, more tasks scaled) or a
pricing change (NAT data processing, a forgotten `desired_count` bump).
Three levers: (1) **Right-size and commit** — check actual CPU/memory
utilization against requests/limits, and buy Savings Plans or Compute
Savings for the steady-state baseline rather than paying on-demand. (2)
**NAT Gateway data processing** — often the silent biggest line item; check
if it's driven by image pulls (move to VPC endpoints for ECR/S3) or chatty
cross-AZ traffic. (3) **Autoscaling bounds and idle environments** — confirm
`max_count` isn't masking a scaling bug, and that staging doesn't run
production-sized `desired_count` around the clock when it could scale to
near-zero outside working hours.
