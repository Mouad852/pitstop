# Platform bootstrap

Applied by hand, **before** Argo CD syncs this repo. Deliberately not
managed by the `pitstop` Application: it ships the SealedSecret CRD, and
the Application runs with `prune: true` — losing the file from Git would
delete the CRD and with it every SealedSecret in the cluster.

## Sealed Secrets (v0.39.1)

    kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.39.1/controller.yaml
    kubectl apply -f platform/sealed-secrets-rbac.yaml

`sealed-secrets-rbac.yaml` **is** Argo-managed. It replaces the upstream
cluster-wide ClusterRoleBinding with namespace-scoped RoleBindings, so
the controller can only touch Secrets in `kube-system` and `pitstop`.
After applying it, remove the upstream binding:

    kubectl delete clusterrolebinding sealed-secrets-controller

The controller must also be told to watch only those namespaces —
RBAC alone leaves it erroring on namespaces it can no longer read:

    kubectl -n kube-system patch deploy sealed-secrets-controller --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["--all-namespaces=false","--additional-namespaces=pitstop"]}]'

## Private key

The controller's signing key is in `kube-system`, secret label
`sealedsecrets.bitnami.com/sealed-secrets-key=active`. It is **not** in
this repo and never should be. It is backed up out-of-band; without it
every SealedSecret here is permanently undecryptable. The controller
rotates it every 30 days (`--key-renew-period`, default 720h), so the
backup must be refreshed.

## etcd encryption at rest

The API server encrypts Secrets before writing them to etcd. Config lives
on the node at `/var/lib/minikube/certs/enc.yaml` (mode 0600, root) —
that path is already mounted into the kube-apiserver static pod, so only
a flag needed adding, no volume changes:

    - --encryption-provider-config=/var/lib/minikube/certs/enc.yaml

Provider order in that file is load-bearing: `aescbc` first (used for
writes), `identity` last (so pre-existing plaintext records stay
readable). Reversing them silently disables encryption; omitting
`identity` before the migration makes every existing Secret unreadable.

The flag only affects new writes. Existing records were migrated with:

    kubectl get secrets --all-namespaces -o json | kubectl replace -f -

Verify against etcd directly — nothing at the kubectl layer can tell you
whether this works, since decryption is transparent:

    kubectl -n kube-system exec etcd-minikube -- etcdctl \
      --cacert=/var/lib/minikube/certs/etcd/ca.crt \
      --cert=/var/lib/minikube/certs/etcd/server.crt \
      --key=/var/lib/minikube/certs/etcd/server.key \
      get /registry/secrets/pitstop/rabbitmq-credentials | strings | head

Expect `k8s:enc:aescbc:v1:key1` and no readable values.

**`enc.yaml` is NOT in this repo and must never be.** It is backed up
out-of-band alongside the sealing key. Losing it makes every Secret in
etcd permanently unreadable. It survives `minikube stop`, not
`minikube delete`.

Limitation: the encryption key sits on the same node as etcd, so this
protects snapshots and backups, not an attacker who owns the node.
A KMS provider with an external key removes that gap (Volet 5 / EKS).

## DAST reachability

The `dast` job in `.gitlab-ci.yml` runs on the `wsl-local` runner, whose
job containers sit on the `pitstop-ci` Docker network. The cluster lives
in the `minikube` container on its own bridge, and Docker isolates
bridges from each other — so by default ZAP has no route to the app.

The ingress controller uses `hostPort: 80/443`, meaning nginx binds the
node container's network namespace directly and answers on **any** IP
that container holds. So attaching the node to the CI network is enough:

    docker network connect --alias pitstop.local pitstop-ci minikube

The `--alias` is not cosmetic. The Ingress routes on `host: pitstop.local`;
without the alias every request carries `Host: minikube`, gets a 404, and
the scan reports success having tested nothing. Verify with:

    docker run --rm --network pitstop-ci curlimages/curl:latest \
      -s -o /dev/null -w '%{http_code}\n' http://pitstop.local/

Survives `minikube stop`/`start`, **not** `minikube delete` — re-run it
after any cluster rebuild.

Trade-off, accepted deliberately: this gives every CI job container
network access to the Kubernetes node, including the API server port.
Acceptable for a local learning cluster and reversible with
`docker network disconnect`. In a real environment DAST would run against
a dedicated staging deployment instead, so the scanner never needs a
path into anything else.

### Restarting the cluster with the DAST network attached

`minikube start` **fails** while the node container is attached to a second
Docker network:

    StartHost failed ... container addresses should have 2 values, got 3

minikube's provisioner expects exactly one address, and the `pitstop-ci`
attachment adds a second. Detach before starting, re-attach after:

    docker network disconnect pitstop-ci minikube
    minikube start
    docker network connect --alias pitstop.local pitstop-ci minikube

The error message suggests `minikube delete`. **Do not.** That destroys the
sealed-secrets private key and `/var/lib/minikube/certs/enc.yaml`, which
makes every SealedSecret in this repo permanently undecryptable and every
Secret in etcd unreadable.

### Reaching the app in a browser

    kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8200:80

Then http://pitstop.local:8200, with `127.0.0.1  pitstop.local` in the
Windows hosts file. The hostname matters, not just the port — the Ingress
routes on `host: pitstop.local`, so `localhost:8200` 404s.

WSL runs with `networkingMode=mirrored`, so Windows and WSL share one TCP
port space and WSL inherits Hyper-V's reserved port ranges. A port inside
a reserved range fails to bind with "address already in use" while nothing
is listening. Check before hunting for a process:

    netsh interface ipv4 show excludedportrange protocol=tcp

8081-8180 was reserved as of 2026-08-24, which ruled out 8088 and 8090.
The ranges are allocated at boot and move.

### minikube memory: the cgroup limit is NOT what the cluster reports

`minikube` auto-selected a **3.9 GiB** memory limit for its container and never
announced it. `kubectl get node` reported ~15.3 GiB, because the kubelet reads
`/proc/meminfo`, which inside a container shows the HOST's memory rather than
the cgroup ceiling. Kubernetes therefore scheduled against a figure four times
larger than reality.

The result was permanent kernel reclaim — evict page cache, re-read from disk,
evict again — which presented as 65% iowait, load average 50+ with idle CPUs,
etcd reads taking 600-975ms, API transactions timing out after 81 seconds, and
argocd-repo-server being killed by its liveness probe 46 times.

Check the truth with docker, not kubectl:

    docker inspect minikube --format '{{.HostConfig.Memory}}' | numfmt --to=iec
    docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}'

Raise it in place — this does NOT require recreating the cluster, and
`minikube delete` would destroy the sealing key and enc.yaml:

    docker update --memory=8g --memory-swap=8g minikube

Setting memory-swap equal to memory disables swap inside the container, which
is what turns memory pressure into disk thrashing.

After the change: iowait 65% -> 0%, load 52 -> 1.0, etcd warnings from ~23/min
at 600-975ms down to 3 per 10 minutes with a worst case of 127ms.

`docker update` applies to the existing container only. `minikube config set
memory 8192` records the intent for a future cluster build.

**Raised again to 10 GiB on 2026-09-02** for Istio sidecar overhead — the
kubelet-reported ~15.3 GiB capacity is still wrong for the same reason as
above; only `docker inspect`/`docker stats` show the real ceiling:

    docker update --memory=10g --memory-swap=10g minikube

### SonarQube is not always-on

`~/pitstop/sonarqube/docker-compose.yml` holds SonarQube plus Postgres, and its
embedded Elasticsearch idles at ~2.5 GiB. All WSL distros share one memory
budget, so leaving it up costs the cluster real headroom.

    cd ~/pitstop/sonarqube && docker compose stop     # when not building
    cd ~/pitstop/sonarqube && docker compose start    # before pushing

The `sonarqube` CI job uses `-Dsonar.qualitygate.wait=true` and does not allow
failure, so **pipelines will fail while it is stopped**. Start it before any
push that triggers a pipeline.

## Istio service mesh (v1.30.3)

Installed via Helm (`istio-base` + `istiod`) into `istio-system`, values in
`platform/istio-values.yaml`. Excluded from Argo's sync the same way as
`monitoring-values.yaml`/`loki-values.yaml` — the `platform/*-values.yaml`
pattern in the Application's `exclude` list — because it is Helm-managed
infrastructure, not an application manifest; `prune: true` on the `pitstop`
Application would otherwise fight the Helm release for ownership.

Sidecar-injected into every `pitstop` workload except the four data-layer
StatefulSets (`rabbitmq`, `mysql-customer`, `mysql-vehicle`,
`mysql-workshop`) — see `docs/security.md` for the mTLS/`AuthorizationPolicy`
design and why those four are excluded.

Sidecar resource requests are trimmed below the chart's defaults
(30m/96Mi). Reason: the scheduler trusts the kubelet-reported node
capacity, which the "minikube memory" section above already shows is wrong
on this host — real capacity is the Docker cgroup limit, not
`/proc/meminfo`. Overcommitting sidecars here would reproduce the same
iowait incident documented above, at the pod-scheduling layer instead of
the container-memory layer.

### After a Docker Desktop / WSL restart, `kubectl` may hang or time out

Two independent failure modes were hit restarting minikube after a host
restart, neither one cluster data loss:

**Stale kubeconfig port.** minikube on the Docker driver maps the API
server's `8443/tcp` to a random host port. A container restart can get a
*different* mapped port from Docker, but nothing updates the kubeconfig
automatically — `kubectl` then dials a dead port and hangs until timeout
(`dial tcp 127.0.0.1:<old-port>: i/o timeout`). Fix:

    minikube update-context

**kubelet does not restart itself.** After the container comes back up,
`docker exec minikube systemctl status kubelet` can show `inactive (dead)`
— every pod in `crictl ps -a`, control plane included, sits `Exited`. Rule
out an OOM kill first (`docker inspect minikube --format
'{{.State.OOMKilled}}'`); if that is `false`, kubelet simply never
restarted. Fix is the same command already documented above for the
network-attach failure, and it is idempotent and safe to re-run on a live
cluster:

    minikube start

If the node is attached to a second Docker network (`pitstop-ci`), detach
it first per "Restarting the cluster with the DAST network attached"
above, or `minikube start` fails on the same IP-parsing bug.

Diagnostic order that separates these causes from an actually broken
cluster: `docker ps` (container up?) → `docker inspect ... OOMKilled` (did
it crash?) → `kubectl config view --minify` vs `docker port minikube`
(right port?) → `docker exec minikube systemctl status kubelet` (control
plane alive?). Only after all four check out is `kubectl get nodes`
expected to work.

### Verified: mTLS and authorization actually enforce, not just apply

Same principle as the rest of this repo — a resource existing is not proof
it does anything:

    # legitimate path still works
    curl -H "Host: pitstop.local" http://localhost:8200/api/customers/ping
    # -> 200

    # direct bypass, from another mesh pod, is rejected
    kubectl exec deploy/vehicle -c vehicle -- \
      wget -qO- --timeout=5 http://customer:3001/api/customers/ping
    # -> 403 Forbidden
