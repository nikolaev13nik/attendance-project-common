# attendance-platform chart

Shared infrastructure for the Attendance system: namespace, ConfigMap, Postgres,
Kafka, Ingress. The two Spring services live in their own repos and depend on this
chart's five shared names — they must never be depended on in return.

| Contract name | Kind | Used by |
| --- | --- | --- |
| `attendance` | Namespace | everything |
| `attendance-config` | ConfigMap | both services |
| `attendance-secrets` | Secret | both services + Postgres |
| `postgres` | Service | both services |
| `kafka` | Service | TimeTracking |

---

## Install order — three owners, and why it is not pure Helm

Run from `attendance-project-common/helm/`.

### 1. Namespace (once, outside Helm)

```bash
kubectl create namespace attendance
```

**Why not the chart?** Helm writes its release record (a Secret) *into* the release
namespace **before** applying any template, so a chart can never bootstrap the
namespace it installs into. Verified 2026-09-28:

```
Error: INSTALLATION FAILED: create: failed to create: namespaces "probe2" not found
```

`helm install --create-namespace` also works and is a valid alternative — Helm
creates it as a pre-step and stamps its own ownership metadata on it.

**But `namespace.create` defaults to `false` anyway**, because with `true` the
Namespace becomes a *release resource* and `helm uninstall` deletes it — taking the
Secret below and both PVCs with it. On k3s `local-path` (`reclaimPolicy: Delete`)
that erases the Postgres data directory from disk. Verified: uninstall put the
namespace straight into `Terminating`.

### 2. Secret (once, outside Helm)

```bash
kubectl create secret generic attendance-secrets \
  --namespace attendance \
  --from-env-file=../.env
```

**Why not the chart?** A Kubernetes Secret is only base64-**encoded**, not
encrypted, and `values.yaml` is committed to git. Putting passwords in either
means committing them. No template renders this Secret, on purpose.

This is *not* an ownership violation. The rule is **one object, one owner** — not
"Helm creates everything." A `kubectl`-created Secret that no template renders has
exactly one owner.

### 3. The chart

```bash
helm upgrade --install platform ./platform \
  --namespace attendance \
  -f platform/values-local.yaml \
  --wait --timeout 5m
```

`--wait` matters here, see the failure mode below.

### 4. The two service charts

Each service owns its own chart, in its own repo. They are separate Helm releases,
so each can be upgraded and rolled back independently of the other and of the
platform.

```bash
helm upgrade --install accounting ~/IdeaProjects/Attendance-Accounting/helm/accounting \
  --namespace attendance --set image.tag=1.0.4 \
  --wait --timeout 10m

helm upgrade --install timetracking ~/IdeaProjects/Attendance-TimeTracking/helm/timetracking \
  --namespace attendance --set image.tag=1.0.12 \
  --wait --timeout 10m
```

`--set image.tag` rather than a version committed in a manifest: that is what keeps
a deploy from being a git change, which would otherwise trigger CI and build yet
another version. The chart falls back to `Chart.yaml`'s `appVersion` when the flag
is omitted.

The timeout is generous because the images are ~500MB and are pulled from GHCR on
first use. That pull happens *before* the container starts, so it is not on the
startup probe's clock.

---

## Failure mode worth recognising: a missing Secret installs "successfully"

`secretKeyRef` is resolved by the **kubelet at container start**, not by Helm at
install time. So if `attendance-secrets` is absent, `helm install` reports
`STATUS: deployed` and exits 0, while the pods sit in:

```
CreateContainerConfigError   secret "attendance-secrets" not found
```

The kubelet retries forever, so creating the Secret afterwards heals the pods with
no further action — order is convenience, not correctness.

`--wait` converts this silent success into a visible timeout failure, which is what
you want in a pipeline.

**Verified end to end on 2026-09-30**, by tearing the whole system down and
rebuilding it from an empty cluster. Observed, in order:

1. `kubectl create namespace attendance` — the chart cannot do this, because Helm
   writes its release record into the namespace before applying any template.
2. Platform chart installed with the Secret deliberately absent and **no** `--wait`:
   `helm list` showed `STATUS: deployed, REVISION 1`, while `postgres` sat in
   `CreateContainerConfigError: secret "attendance-secrets" not found`. Kafka came
   up healthy, because it reads no secrets — the failure is scoped to what is
   genuinely missing.
3. `kubectl create secret ... --from-env-file=../.env` — postgres reached `1/1
   Running` on its own, **keeping the same pod name**. The pod object was never
   wrong; only container creation failed, and the kubelet retries that on a backoff.
   No rollout, no restart, no second command.
4. Both service charts installed **with** `--wait`, which held the release in
   `pending-install` until the pods passed their probes.
5. `POST /account/login` through the Ingress returned 200; that token was then
   accepted by TimeTracking, while the same request without it returned 401.

Total objects recreated: 9 from the platform chart, 2 from each service chart.

---

## Environments

One chart, one values file per target. Never a second copy of the chart.

```bash
helm upgrade --install platform ./platform -n attendance -f platform/values-local.yaml
helm upgrade --install platform ./platform -n attendance -f platform/values-aws.yaml
```

| | local (k3s) | AWS (EKS) |
| --- | --- | --- |
| Postgres | pod + PVC | **RDS** — `postgres.enabled=false` |
| Kafka | pod + PVC | **MSK** — `kafka.enabled=false` |
| storage class | `local-path` | `gp3` (EBS CSI) |
| ingress class | `traefik` | `alb` + AWS Load Balancer Controller |
| secrets | `kubectl create secret` from `.env` | Secrets Manager + External Secrets Operator |

`values-local.yaml` is nearly empty by design — `values.yaml`'s defaults already
describe the local setup, so it exists only to make the deploy command state its
target explicitly.

---

## Protecting data

Anything holding data should carry:

```bash
kubectl annotate namespace attendance     helm.sh/resource-policy=keep --overwrite
kubectl annotate pvc postgres-pvc -n attendance helm.sh/resource-policy=keep --overwrite
kubectl annotate pvc kafka-pvc    -n attendance helm.sh/resource-policy=keep --overwrite
```

Helm then refuses to delete these during an upgrade-prune or an uninstall. Without
it, flipping `postgres.enabled` to `false` on a live release prunes `postgres-pvc`
and the data is gone.

---

## Useful commands

```bash
helm lint ./platform
helm template p ./platform                        # render, touch nothing
helm template p ./platform | kubectl diff -f -    # empty == chart matches cluster
helm history platform -n attendance
helm rollback platform <revision> -n attendance
```

`--force-conflicts` is needed only when migrating an object previously managed by
plain `kubectl apply`, and only the first time Helm changes each field.
