# Kubernetes deployment

Manifests are split by ownership, the way most teams do it at scale.

```
attendance-project-common/k8s/     PLATFORM - shared, owned by nobody in particular
├── namespace.yaml                 the "attendance" namespace
├── configmap.yaml                 non-secret config both services read
├── secrets.example.yaml           template only; the real Secret is created from ../.env
├── postgres.yaml                  Deployment + Service + PVC
├── kafka.yaml                     Deployment + Service + PVC
└── ingress.yaml                   single entry point (Step 16)

Attendance-Accounting/k8s/         owned by the Accounting service
└── accounting.yaml                its Deployment + Service

Attendance-TimeTracking/k8s/       owned by the TimeTracking service
└── timetracking.yaml              its Deployment + Service
```

## The contract between them

A service manifest may rely on the platform, never the other way round. Each
service Deployment assumes these already exist:

| Platform provides | Service consumes it as |
| --- | --- |
| namespace `attendance` | `metadata.namespace` |
| ConfigMap `attendance-config` | `configMapKeyRef` |
| Secret `attendance-secrets` | `secretKeyRef` |
| Service `postgres` | the JDBC host |
| Service `kafka` | `KAFKA_BOOTSTRAP_SERVERS` |

Those five names are the interface. Renaming one breaks both services, so treat
them as public API.

## Deploy order

Platform first — a service pod referencing a missing ConfigMap or Secret will not
start, it stays in `CreateContainerConfigError`.

```bash
# 1. platform
cd attendance-project-common/k8s
kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml
kubectl create secret generic attendance-secrets \
  --namespace attendance --from-env-file=../.env      # only once; not idempotent
kubectl apply -f postgres.yaml -f kafka.yaml

# 2. services (any order; they are independent)
kubectl apply -f ../../Attendance-Accounting/k8s/
kubectl apply -f ../../Attendance-TimeTracking/k8s/
```

## Everyday commands

```bash
kubectl get all -n attendance
kubectl get pods -n attendance -w
kubectl logs -f -n attendance deploy/accounting
kubectl rollout restart deploy/accounting -n attendance

# reach the cluster from your Mac (all services, real names, real ports)
sudo -v && sudo -E nohup kubefwd svc -n attendance > /tmp/kubefwd.log 2>&1 & disown
sudo pkill -INT kubefwd          # -INT, not -9: it restores /etc/hosts
```

## Teardown

```bash
kubectl delete namespace attendance      # removes everything in it, including the PVCs
```

## Notes

- Images are built locally (`Dockerfile.dev` in each service repo) and referenced
  with `imagePullPolicy: Never`. This works only because Rancher Desktop's k3s
  uses the same dockerd as `docker build`. Pulling from GHCR instead is Step 17.
- Postgres and Kafka run as Deployments with `strategy: Recreate`. Production
  would use StatefulSets - see the plan file for why.
