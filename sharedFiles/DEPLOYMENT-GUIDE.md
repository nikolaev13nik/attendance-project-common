# Deploying the Attendance system — three ways

The same two services deployed three different ways, each building on the last.
Read top to bottom: every stage assumes the files from the one before it.

| Stage | Tool | What it adds |
| --- | --- | --- |
| 1 | Docker Compose | containers on one machine |
| 2 | Kubernetes manifests | scheduling, self-healing, probes, one entry point |
| 3 | Helm | one parameterised template per environment, rollback |
| 4 | Argo CD | git as the only deploy mechanism *(current state)* |

## The system

| Repo | Contains |
| --- | --- |
| `Attendance-Accounting` | issues JWTs. Java 17 / Spring Boot |
| `Attendance-TimeTracking` | validates those JWTs, calls Accounting, publishes to Kafka |
| `attendance-project-common` | no code — all shared infrastructure lives here |

Supporting infrastructure: **PostgreSQL** (one database `attendance`, one schema per
service) and **Kafka** (single-node KRaft).

---

# Prerequisites

- A container runtime + Kubernetes. On macOS: **Rancher Desktop** with the dockerd
  (moby) engine and Kubernetes enabled. It bundles `docker`, `kubectl` and `helm`.
- **Secrets.** Copy `.env.example` to `.env` in `attendance-project-common` and fill
  in real values. `.env` is gitignored and must never be committed.

```
JWT_SECRET                 # 32+ bytes. Generate: openssl rand -base64 48
POSTGRES_PASSWORD
ACCOUNTING_DB_PASSWORD
TIMETRACKING_DB_PASSWORD
BOOTSTRAP_ADMIN_PASSWORD   # the initial super-admin
```

`JWT_SECRET` **must be identical for both services** — that shared value is what makes
a token issued by Accounting valid in TimeTracking.

---

# Stage 1 — Docker Compose

Everything on one machine, one network, one command.

## Files

| File | Repo | Purpose |
| --- | --- | --- |
| `docker-compose.yml` | common | all four services: postgres, kafka, accounting, timetracking |
| `.env` | common | secrets, read by Compose via `${VAR}` |
| `helm/platform/files/init-db.sh` | common | creates the database, both schemas, both restricted DB users |
| `Dockerfile.dev` | **each service** | multi-stage build **from source** — used by Compose |
| `Dockerfile.dev.dockerignore` | **each service** | excludes `target/` from the build context |
| `Dockerfile` | **each service** | used by **CI only** — copies a jar built on the runner |
| `.dockerignore` | **each service** | must **not** exclude `target/`, or CI's build breaks |

> Two Dockerfiles per service on purpose. CI builds the jar first and copies it in;
> local builds compile inside the image. Docker picks up
> `<Dockerfile>.dockerignore` automatically when it exists.

## Commands

```bash
cd attendance-project-common
cp .env.example .env          # then fill in real values

docker compose up -d --build  # build images and start everything
docker compose ps             # all four should be healthy
docker compose logs -f accounting
```

| Service | URL from your machine |
| --- | --- |
| Accounting | http://localhost:8081 |
| TimeTracking | http://localhost:8082 |
| Postgres | localhost:5432 |
| Kafka | localhost:9094 |

```bash
docker compose down           # stop; named volumes SURVIVE
docker compose down -v        # stop and DELETE the volumes (data gone)
```

**Key idea:** containers reach each other by **service name and container port**
(`http://accounting:8080`), never `localhost` and never the host port.

---

# Stage 2 — Kubernetes manifests

> These files were **retired** once Helm replaced them; they are recoverable from git
> history (`git log -- k8s/`). Documented here because this is the stage where the
> Kubernetes concepts are learned, before templating hides them.

## Files

| File | Repo | Contains |
| --- | --- | --- |
| `k8s/namespace.yaml` | common | the `attendance` namespace |
| `k8s/configmap.yaml` | common | non-secret config shared by both services |
| `k8s/postgres.yaml` | common | Deployment + Service + PersistentVolumeClaim + init ConfigMap |
| `k8s/kafka.yaml` | common | Deployment + Service + PersistentVolumeClaim |
| `k8s/ingress.yaml` | common | one entry point routing `/account` and `/attendance` |
| `k8s/accounting.yaml` | **Accounting** | its own Deployment + Service |
| `k8s/timetracking.yaml` | **TimeTracking** | its own Deployment + Service |

**Ownership rule:** shared infrastructure lives in the common repo; each service owns
only its own Deployment and Service. Services depend on the platform, never the
reverse. The interface is five names:

```
namespace attendance · ConfigMap attendance-config · Secret attendance-secrets
Service postgres · Service kafka
```

## Commands

```bash
kubectl create namespace attendance

# the Secret is NOT in git — created from .env
kubectl create secret generic attendance-secrets -n attendance --from-env-file=.env

kubectl apply -f k8s/                                        # platform first
kubectl apply -f ../Attendance-Accounting/k8s/accounting.yaml
kubectl apply -f ../Attendance-TimeTracking/k8s/timetracking.yaml

kubectl get pods -n attendance -w
```

Add `127.0.0.1 attendance.local` to `/etc/hosts`, then both services are reachable at
`http://attendance.local/account` and `http://attendance.local/attendance`.

**Why this stage gets replaced:** every value is hardcoded, so a second environment
means a second copy of every file, and `kubectl apply` has no rollback.

---

# Stage 3 — Helm

Same objects, now templated. One chart per repo, three independent releases.

## Files

```
attendance-project-common/helm/platform/
├── Chart.yaml                  name, chart version, appVersion
├── values.yaml                 defaults (describe the LOCAL setup)
├── values-local.yaml           explicit local target (nearly empty by design)
├── values-aws.yaml             the AWS deltas only
├── files/init-db.sh            pulled in by a template, not applied directly
├── templates/                  namespace, configmap, postgres, kafka, ingress
└── README.md                   the canonical install order

Attendance-Accounting/helm/accounting/
├── Chart.yaml
├── values.yaml
└── templates/{deployment,service}.yaml

Attendance-TimeTracking/helm/timetracking/   (same shape)
```

**Only files in `templates/` become Kubernetes objects.** `values.yaml` and
`Chart.yaml` are inputs for Helm; `files/` holds data a template reads.

### Two versions in `Chart.yaml`, often confused

```yaml
version: 0.2.0        # the CHART — bump when templates or values change
appVersion: "1.0.4"   # the default image tag — bump to deploy a new build
```

## Commands

Three owners, in order. **Namespace and Secret are deliberately not Helm's job** — a
chart cannot create the namespace its own release record lives in, and a Kubernetes
Secret is only base64-encoded, so its values must never be committed.

```bash
cd attendance-project-common

# 1. namespace (once)
kubectl create namespace attendance

# 2. secret (once, from .env)
kubectl create secret generic attendance-secrets -n attendance --from-env-file=.env

# 3. platform
helm upgrade --install platform ./helm/platform \
  -n attendance -f helm/platform/values-local.yaml --wait --timeout 5m

# 4. the two services
helm upgrade --install accounting ../Attendance-Accounting/helm/accounting \
  -n attendance --set image.tag=1.0.4 --wait --timeout 10m

helm upgrade --install timetracking ../Attendance-TimeTracking/helm/timetracking \
  -n attendance --set image.tag=1.0.12 --wait --timeout 10m
```

Always `upgrade --install`, never `install` — it works whether or not the release
already exists, so the same command serves the first deploy and the hundredth.

### Useful

```bash
helm list -n attendance                             # what is installed
helm template p ./helm/platform                     # render without applying
helm template p ./helm/platform | kubectl diff -f - # empty = chart matches cluster
helm history platform -n attendance
helm rollback platform 3 -n attendance              # something kubectl apply cannot do
```

### Another environment — one file, not a second copy of the chart

```bash
helm upgrade --install platform ./helm/platform -n attendance -f helm/platform/values-aws.yaml
```

`values-aws.yaml` sets `postgres.enabled=false` and `kafka.enabled=false`, so those
pods do not render at all (managed AWS services replace them), switches the ingress
class to `alb`, and points the config at RDS/MSK endpoints.

> **Failure mode to recognise:** if the Secret is missing, `helm install` still reports
> `STATUS: deployed`, because `secretKeyRef` is resolved by the kubelet at
> container-start, not by Helm. The pods sit in `CreateContainerConfigError`. Creating
> the Secret afterwards heals them with no further command. `--wait` turns that silent
> success into a visible failure.

---

# Stage 4 — Argo CD (GitOps) — current state

Argo CD runs **inside** the cluster and pulls from GitHub. Deploying becomes
`git push`; nothing outside needs access to the cluster.

## Files

| File | Purpose |
| --- | --- |
| `helm/argocd-values.yaml` | values for the third-party `argo/argo-cd` chart |
| `argocd/accounting-application.yaml` | points Argo at `Attendance-Accounting/helm/accounting` |
| `argocd/timetracking-application.yaml` | points Argo at `Attendance-TimeTracking/helm/timetracking` |

## Commands

```bash
helm repo add argo https://argoproj.github.io/argo-helm

helm upgrade --install argocd argo/argo-cd --version 10.9.4 \
  -n argocd --create-namespace -f helm/argocd-values.yaml

kubectl apply -f argocd/accounting-application.yaml
kubectl apply -f argocd/timetracking-application.yaml
```

UI at `http://argocd.local` (add it to `/etc/hosts`). Initial password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

## How you deploy now

```bash
# edit helm/<service>/values.yaml or bump appVersion in Chart.yaml
git commit -am "..." && git push
```

That is the whole deployment. Argo CD notices within ~3 minutes and applies it.
Roll back with `git revert`. The deployed version is a **commit SHA**, visible as
`kubectl get application <name> -n argocd -o jsonpath='{.status.sync.revision}'`.

With `selfHeal: true`, any change made with `kubectl` or `helm` against these two
services is reverted within seconds. Git is the only way in. The **platform** chart is
still plain Helm and is upgraded by hand.

---

# Quick reference

| I want to... | Command |
| --- | --- |
| run everything on one machine | `docker compose up -d --build` |
| install into Kubernetes | `kubectl create ns` + `kubectl create secret` + 3 × `helm upgrade --install` |
| see what is installed | `helm list -n attendance` / `kubectl get applications -n argocd` |
| preview a chart without applying | `helm template p ./helm/platform` |
| check the cluster matches the chart | `helm template p ./helm/platform \| kubectl diff -f -` |
| roll back (Helm-managed) | `helm rollback platform 3 -n attendance` |
| roll back (Argo-managed) | `git revert <sha> && git push` |
| deploy a new build | bump `appVersion` in the service's `Chart.yaml`, commit, push |
| tear everything down | `helm uninstall platform -n attendance` then `kubectl delete ns attendance` |

## Things that cost time to discover

- **Quote anything numeric in `values.yaml`.** `id: 123456789` unquoted becomes
  `"1.23456789e+08"`. Same for `"5432"` and `restart: "no"` in Compose.
- **Helm silently ignores unknown values keys** unless a chart ships
  `values.schema.json`. A typo gives no error — verify the rendered output.
- **Changing a ConfigMap does not restart pods.** Environment variables are injected
  once, at container start. Use `kubectl rollout restart`, or a checksum annotation.
- **`kubectl apply` and Helm fight over field ownership.** Once a chart owns an
  object, do not `kubectl apply` a manifest for it — the first Helm upgrade afterwards
  fails with a conflict.
