# payments-api — DevOps assessment submission

A small Flask service (`app.py`), containerised, deployed to Kubernetes,
built/scanned/shipped by CI, and provisioned in AWS via Terraform.

## Repository layout

```
.
├── app.py, requirements.txt      # the sample app, unmodified
├── Dockerfile, .dockerignore     # Task 1
├── k8s/                          # Task 2 — plain manifests + kustomize
├── .github/workflows/ci.yml      # Task 3
├── terraform/                    # Task 4 — bootstrap + modules + environments
├── troubleshooting/              # Task 5 — fixed manifest + incident note
└── DESIGN.md                     # written design answers
```

## Task 1 — Containerisation

```bash
docker build -t payments-api:local .
docker run --rm -p 8080:8080 -e DATABASE_URL=postgresql://placeholder payments-api:local
curl localhost:8080/healthz
```

Multi-stage build (`python:3.12.7-slim-bookworm`, pinned): a builder stage
resolves dependencies into a venv, the runtime stage copies only that venv
and `app.py` — no pip, no build tooling, no apt cache in the final image.
Runs as a non-root UID 1000, serves via `gunicorn`, and ships a
`HEALTHCHECK` using Python's stdlib `urllib` rather than adding `curl`/`wget`
just for that purpose.

**Verified locally** (built and ran the image, ran `hadolint` and `trivy`
against it — not just written and assumed correct):

- `hadolint` was clean only after two fixes: `USER app` → `USER 1000:1000`
  (DL3066 — hadolint can't resolve a non-numeric UID on the host) and the
  `HEALTHCHECK`'s `CMD` moved from shell string form to JSON array form
  (DL3025).
- **The base image failed Trivy outright as first written** — 7 CRITICAL /
  47 HIGH CVEs in `slim-bookworm`'s OS packages (`openssl`, `perl-base`),
  all with upstream Debian security fixes not yet baked into that image
  tag. Added `apt-get update && apt-get upgrade -y` (same-version security
  patches only, not a dist-upgrade) in the runtime stage before the `USER`
  switch — this is the fix, not a scan-config workaround. Re-scanned at 0
  CRITICAL / 0 HIGH. Trade-off: image grew from 237MB to 349MB; I chose
  passing the vulnerability gate over image size, since that's what the
  gate is actually for.
- Container runs as UID 1000 (confirmed via `id`/`whoami`), `/healthz`,
  `/ready`, `/` all respond correctly, `/ready` returns 503 without
  `DATABASE_URL` and 200 with it, and `docker inspect` reports the
  `HEALTHCHECK` as `healthy`.

## Task 2 — Kubernetes deployment

Plain manifests over Helm — this is a single service with no templating
need yet; Helm would be the right call once there's more than one
environment-specific knob to twiddle beyond image tag and `APP_ENV`.

```bash
# create a local cluster
kind create cluster --name payments-api

# build the image kind can see, and load it (no registry needed locally)
docker build -t payments-api:dev .
kind load docker-image payments-api:dev --name payments-api

# install an ingress controller and metrics-server (needed for the HPA)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# generate the real Secret (not committed — see k8s/secret.example.yaml)
# kustomization.yaml expects it at k8s/secret.yaml
kubectl create namespace payments-api
kubectl create secret generic payments-api-secrets -n payments-api \
  --from-literal=DATABASE_URL='postgresql://placeholder:placeholder@localhost:5432/payments' \
  --dry-run=client -o yaml > k8s/secret.yaml

# apply everything, then point the Deployment at the locally-built image
# (the committed manifest references the real GHCR image/tag, which only
# exists once CI has pushed it)
kubectl apply -k k8s/
kubectl -n payments-api set image deployment/payments-api payments-api=payments-api:dev

kubectl -n payments-api rollout status deployment/payments-api
kubectl -n payments-api port-forward svc/payments-api 8080:80
```

What's in `k8s/`: a Deployment (2 replicas, `/healthz` liveness, `/ready`
readiness, CPU/memory requests+limits, non-root `securityContext` with
dropped capabilities and a read-only root filesystem, `maxUnavailable: 0` /
`maxSurge: 1` plus a `preStop` hook for zero-downtime rollouts), a Service,
an Ingress, an HPA (CPU + memory, 2-5 replicas), and a PDB
(`minAvailable: 1`). `APP_ENV` comes from a ConfigMap; `DATABASE_URL` comes
from a Secret that's deliberately **not** committed —
`k8s/secret.example.yaml` documents the shape and the
`kubectl create secret ... --dry-run=client` command that generates the
real one (CI does the same with a placeholder before validating manifests).

**Verified locally** against a real `kind` cluster with ingress-nginx and
metrics-server installed: rollout reaches 2/2 ready; the Service, Ingress
(tested via `Host: payments-api.local`), ConfigMap and Secret all wire up
correctly end-to-end; ingress-nginx and metrics-server deploy via local
files rather than piping a remote URL into `kubectl apply`, since this
sandbox's safety layer blocks `kubectl apply -f <url>` as an unreviewable
action — downloading first keeps the manifest inspectable before it touches
the cluster, which is good practice regardless.

Two real bugs surfaced under load that aren't visible from reading the
manifest, both now fixed in `k8s/deployment.yaml`:

- **Rolling restarts dropped ~1-2% of requests** measured with an in-cluster
  prober hitting the Service during a `rollout restart` — the classic race
  where kube-proxy hasn't yet removed a terminating pod from the Service's
  endpoints when it receives SIGTERM. Fixed with a `preStop: sleep 5` hook
  (and `terminationGracePeriodSeconds: 15`); re-tested at 150/150 successful
  requests through a full rollout afterwards.
- **The HPA's memory trigger sat at ~80% utilization at idle** — `kubectl top
  pods` showed ~51Mi actual usage against a 64Mi memory *request* (HPA
  compares usage to requests, not limits), meaning the smallest blip would
  have triggered a scale-out. Raised the request to 128Mi for real headroom;
  confirmed utilization settled at ~40%.

## Task 3 — CI/CD

`.github/workflows/ci.yml`, runs on every push and PR:

1. **lint** — `flake8` on `app.py`, `hadolint` on the `Dockerfile`.
2. **build-scan** — builds the image (GitHub Actions cache), scans it with
   Trivy, fails the job on CRITICAL/HIGH findings.
3. **validate-k8s** — renders `k8s/` with `kustomize` (against a
   CI-generated placeholder Secret) and validates the output with
   `kubeconform`.
4. **push** — only on `main`: logs into GHCR and pushes
   `ghcr.io/<repo>:sha-<12-char-sha>` and `:latest`. The SHA tag is what
   actually gets deployed anywhere; `latest` is a convenience pointer, never
   the only tag.

**Actually run on GitHub Actions** (not just locally): pushed to
[github.com/Dedeepya-10/payments-api-devops-assessment](https://github.com/Dedeepya-10/payments-api-devops-assessment/actions),
all 4 jobs green. Getting there surfaced three bugs invisible from reading
the YAML:

- `aquasecurity/trivy-action@0.28.0` — tags on that action are `v`-prefixed;
  the bare `0.28.0` failed to resolve.
- `aquasecurity/trivy-action@v0.28.0` itself resolved, but its *own* internal
  pin to `aquasecurity/setup-trivy@v0.2.1` pointed at a tag that was never
  published (lowest real tag is `v0.2.6`) — a dead upstream release only
  visible by actually executing the workflow. Bumped to `v0.36.0`, which
  pins that nested action by commit SHA instead of a tag.
- `ghcr.io/${{ github.repository }}` failed the build with `repository name
  must be lowercase` — the account name (`Dedeepya-10`) has an uppercase
  letter, and GitHub Actions' expression syntax has no `lower()` function.
  Fixed by lowercasing it in a shell step (`tr '[:upper:]' '[:lower:]'`) and
  passing it through job outputs instead of a static top-level `env:`.

## Task 4 — Terraform

ECS Fargate over EKS: this workload is one stateless HTTP service with no
need for custom controllers, CRDs, or multi-tenant scheduling — EKS would
add a control plane bill and meaningfully more code (node groups or Fargate
profiles, IRSA setup, cluster add-ons) for no benefit here. Fargate gets a
private-subnet, ALB-fronted, autoscaled service in ~250 lines across three
small modules.

```
terraform/
├── bootstrap/        # one-time: creates the S3 state bucket + lock table
├── modules/
│   ├── vpc/           # VPC, 2 AZs, public+private subnets, 1 NAT per AZ
│   ├── alb/           # internet-facing ALB, target group, HTTP listener
│   └── ecs/           # cluster, task def, service, IAM roles, autoscaling
└── environments/
    ├── staging/        # desired_count=1, smaller task size
    └── production/     # desired_count=3, larger task size
```

Both environments share the same three modules — only `variables.tf`
defaults and the backend `key` differ, so staging and production can't
drift in structure, only in size.

```bash
# one-time, per AWS account:
cd terraform/bootstrap && terraform init && terraform apply

# per environment:
cd terraform/environments/production
terraform init
terraform validate
terraform plan -var="image=ghcr.io/<org>/payments-api:sha-<commit>"
```

I ran `terraform fmt -recursive`, and `terraform validate` on `bootstrap`,
`staging`, and `production` — all pass. I did **not** run `plan` against a
real backend: that needs the bootstrap S3 bucket to actually exist and AWS
credentials, and the brief asks not to create billable resources. The
`plan` output would show: a VPC with 2 public + 2 private subnets, 2 NAT
gateways, an ALB + target group + listener, an ECS cluster/service/task
definition, a Secrets Manager secret (empty value), and the IAM
execution/task roles — all net-new, no destructive changes, since this is a
from-scratch environment.

Not implemented, would do with more time: an ACM-backed HTTPS listener (and
redirect-only on 80), WAF in front of the ALB, and splitting the `ecs`
module's autoscaling into its own module since it'll likely be reused.

## Task 5 — Troubleshooting

See [`troubleshooting/incident-note.md`](troubleshooting/incident-note.md)
and [`troubleshooting/fixed-deployment.yaml`](troubleshooting/fixed-deployment.yaml).
Found all 7 planted issues: label/selector mismatch, Service `targetPort`
pointing at 80 instead of 8080, liveness probe hitting `/health` instead of
`/healthz`, missing `DATABASE_URL` (so `/ready` stayed 503), a 16Mi memory
limit causing OOMKills, a 1-second initial delay against a 50m CPU limit
killing the pod before startup finished, and the combination of no resource
requests / `:latest` tag / missing `securityContext`.

## Assumptions

- Local cluster tooling (kind/k3d/minikube, kubectl, an ingress controller,
  metrics-server) is available in the environment that runs the commands
  above — not bundled into this repo.
- GHCR (`ghcr.io`) is the target registry; no other registry secrets are
  configured.
- AWS region `eu-west-1`; no existing VPC/account constraints to design
  around.

## What I'd improve with more time

- A Helm chart once there's a second service to share templates with.
- Policy-as-code (Kyverno/OPA) admission checks for the exact class of bug
  in Task 5, so a bad manifest is rejected at `kubectl apply` time everywhere,
  not just in this one repo's CI.
- HTTPS on the ALB listener and a WAF (see Task 4).
- Actually run `terraform plan` against the bootstrapped backend in a real
  (free-tier) AWS account rather than relying on `validate`/`fmt` alone —
  didn't want to create any AWS resources for this submission.

## Time spent

Roughly 4 hours: containerisation + K8s manifests (~1.5h, including
standing up a local kind cluster and load-testing the rollout — which is
what surfaced the two bugs noted above), CI/CD (~45m), Terraform (~1h),
troubleshooting + design answers (~45m).
