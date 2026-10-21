# Pitstop — security controls and accepted risks

What this system defends against, what it deliberately does not, and what
has to be true for it to be rebuilt. Written at the close of Volet 3
(pipeline security), 2026-08-24. Extended at the close of Volet 4b
(Istio service mesh), 2026-09-02.

Pitstop is a garage-management app: five services (customer, vehicle,
workshop, an express-gateway front door, and a Vue webapp) built by
GitLab CI, deployed to Kubernetes by Argo CD from this repository.

---

## 1. Pipeline controls

Shared CI templates live in `pitstop-ci-templates` and are included by
every app repo. Stage order is `security → build → scan → deploy`, which
is itself a control: **a leaked credential blocks the image from ever
being built.**

| Job | Tool | Gates? | Threshold |
|---|---|---|---|
| `secret-detection` | Gitleaks | **yes** | any finding fails |
| `dependency-scan` | `trivy fs` | no — report only | HIGH+CRITICAL logged |
| `sonarqube` | SonarQube | **yes** | quality gate, `qualitygate.wait=true` |
| `build-image` | Docker/DinD | n/a | |
| `container-scan` | `trivy image` | **yes** | CRITICAL, fixable only, minus suppressions |
| `update-manifest` | git | n/a | writes the image tag to this repo |

This repo (`pitstop-kubernetes`) additionally runs:

| Job | Tool | Gates? | Threshold |
|---|---|---|---|
| `secret-detection` | Gitleaks | **yes** | any finding, minus the SealedSecret allowlist |
| `zap-baseline` | OWASP ZAP | **yes** | FAIL-level rules only (`-I`); WARN is reported, not blocking |

### Why the thresholds are what they are

**`container-scan` gates on CRITICAL, not HIGH.** `ip@1.1.5`
(CVE-2024-29415) is HIGH with no fixed version, so gating on HIGH would
make every pipeline permanently red — and a permanently red gate gets
bypassed or deleted. `--ignore-unfixed` is applied for the same reason:
fixability is the highest-value filter after severity.

**`dependency-scan` deliberately does not gate.** It scans the lockfile,
which includes build-time dependencies that never ship. The image is what
reaches production, so the image is what gates.

> **This has a real cost.** `dependency-scan` reported
> `moment@2.29.1` (CVE-2022-31129, CVE-2022-24785) into every pipeline log
> for weeks and nobody read it. It took OWASP ZAP, a different tool class
> in a different stage, to surface it. **Findings that do not gate get
> ignored.** Treat the report-only job as a backlog to review, not as
> coverage.

**`zap-baseline` gates on FAIL only.** FAIL-level rules have been 0 across
three consecutive runs; the 6 remaining WARN findings are documented
accepted risks below. The threshold was chosen from measurements, not
guessed.

### When jobs run

Defined once in `pitstop-ci-templates/rules.yml`:

- **`.rules-security`** — every `main` commit, merge requests, and
  **scheduled pipelines**. Scanners whose verdict depends on external data
  (Trivy's vulnerability DB moves without the code moving) belong here.
- **`.rules-image`** — `main` commits that change something which lands in
  the image. Never on a schedule. Sonar sits here, because its verdict
  depends only on this source tree; unchanged code gives an unchanged
  answer.
- **`secret-detection` is never path-gated.** A leaked credential can be
  committed in any file, including ones no build would touch.

Weekly schedules run on all six repos. This is the control that catches
**a CVE published in code that has not changed** — without it, scanning
only on push means a vulnerability disclosed today stays invisible until
someone happens to commit.

---

## 2. Cluster controls

### Secrets

| Control | State |
|---|---|
| Sealed Secrets | v0.39.1; all 5 secrets sealed, committed in `secrets/`, Argo-synced |
| Controller RBAC | scoped to `kube-system` + `pitstop` (upstream default is cluster-wide) |
| etcd encryption at rest | `aescbc`, all existing Secrets migrated |
| Secret access for workloads | `default` SA has none; `automountServiceAccountToken: false` on every pod |

These defend against **three different attackers**, and none substitutes
for the others:

- **Sealing** protects Git. Someone reading the public repository gets
  ciphertext.
- **RBAC** protects the API server. A compromised pod or a leaked
  kubeconfig cannot read credentials it does not need.
- **etcd encryption** protects the disk. Someone with an etcd snapshot or
  a backup tarball gets ciphertext, with no cluster login required.

### Workload hardening

- Non-root user (`appuser`) in every Node image
- `.dockerignore` in all five repos — added after SonarQube found that
  `COPY . .` was shipping the entire `.git` directory inside every image,
  which bypassed Gitleaks completely since the full history travelled in
  the container
- `app.disable('x-powered-by')` in the three Node services
- `helmet()` in the three Node services — `nosniff`, `X-Frame-Options`,
  `Referrer-Policy`, HSTS and more
- Custom nginx config in the webapp — `server_tokens off`, CSP,
  COOP/COEP/CORP, `Permissions-Policy`, plus a SPA history fallback
- Self-hosted CI runner is **not** privileged and has **no Docker socket
  mount** — a socket mount is approximately root on the host, and that
  runner only executes a Java scanner

### Service mesh: mutual TLS and authorization

Istio 1.30.3 (`istio-base` + `istiod`), sidecar-injected into every
`pitstop` workload except the four data-layer StatefulSets. Two Istio
CRDs do the actual enforcement:

| Control | State |
|---|---|
| `PeerAuthentication` | namespace default `STRICT`; `gateway` and `webapp` overridden to `PERMISSIVE` |
| `AuthorizationPolicy` | `customer`, `vehicle`, `workshop` each accept traffic only from `cluster.local/ns/pitstop/sa/gateway` |

**Why `gateway` and `webapp` stay `PERMISSIVE`, not `STRICT`.** Both
receive traffic directly from `ingress-nginx`, which has no sidecar and
so cannot present an Istio certificate. A namespace-wide `STRICT` policy
would reject real user traffic at the door. `customer`/`vehicle`/`workshop`
have no such exposure — only `gateway` calls them — so they take the
`STRICT` default with no behavioural change, since sidecar-to-sidecar
traffic already preferred mTLS under `PERMISSIVE`.

**Why the four StatefulSets (`rabbitmq`, `mysql-customer`, `mysql-vehicle`,
`mysql-workshop`) are not in the mesh.** Each carries
`sidecar.istio.io/inject: "false"`. They speak raw TCP, not HTTP, so a
sidecar adds startup/draining risk with no L7 benefit.

**Only `gateway` has its own ServiceAccount.** `customer`, `vehicle`,
`workshop`, and `webapp` still run as the namespace `default` SA, so the
mesh cannot distinguish their traffic from each other by identity. This is
a deliberate scope cut, not an oversight: the `AuthorizationPolicy` rules
only need to positively identify the *caller* (`gateway`), never to tell
the three backend services apart, so giving all five workloads distinct
identities would have doubled the manifest changes for no additional
enforcement.

**Sidecar memory cost, measured, not assumed:** minikube's Docker
container went from 5.059 GiB to 6.144 GiB (+1.085 GiB) after meshing all
five services — inside the 650 Mi–1.2 GiB estimate made before rolling it
out.

---

## 3. Accepted risks

Each of these is a deliberate decision, not an oversight. Reviewing them
is part of the work; leaving them undocumented would not be.

### Authentication and authorisation

**The gateway performs no authentication.** Anything that reaches the
ingress can call every API. `/api/vehicles/customers/all` returns customer
names — real PII, unauthenticated. This is the single largest gap in the
system and the one a production deployment could not ship with.

**CORS is wildcard** (`app.use(cors())`) on all three Node services.
Confirmed independently by ZAP as `Cross-Domain Misconfiguration`. It is
one decision with the item above, not a separate defect — fixing CORS
while the API stays unauthenticated would be theatre.

### Unmaintained dependencies

The recurring theme of this project: **most remaining risk is unmaintained
code, not unpatched code.** None of these can be fixed by upgrading.

| Component | Issue | Why it cannot be patched |
|---|---|---|
| Vue 2.6.14 | CVE-2024-9506 | Vue 2 EOL Dec 2023; no OSS patch exists (the advisory's HeroDevs link is a commercial vendor). Real risk low: ReDoS in the template compiler, and a precompiled SPA never compiles user input. |
| `express-gateway` | frozen since 2021 | Required forced `overrides` for `ejs`, `form-data`, `minimist`. Remediation is migration, not `npm update`. |
| `amqplib@0.4.2` | 2016 release, `EBADENGINE` on Node 24 | Hard-pinned by `amqp-ts-async` under a declared `^0.8.0`. Fourteen majors outside its engine range. |
| `node-tar` | CVE-2026-59873 | Bundled inside npm in the base image. **No published Node tag ships the fixed 7.5.19** — verified by scanning node:20/22/24-alpine before deciding. |

### Suppression with an expiry — review 2026-11-30

`CVE-2026-59873` is suppressed in `.trivyignore.yaml` across all five app
repos with `expired_at: 2026-11-30`. **The expiry is the point** — an
exception without one is a permanent hole with a comment on it. Verified
empirically: setting the date into the past does make the gate fail again.

> **On 2026-11-30 all five pipelines go red simultaneously, by design.**
> Put it in a calendar and meet it as a scheduled review.

### Structural, inherent to the architecture

**Argo CD can read the sealing private key.** Both `argocd-server` and
`argocd-application-controller` have `get secrets` in `kube-system`. So:
Argo login → the private key → decrypt this public repository → every
credential. This is **not fixable by reducing Argo's permissions** — any
GitOps controller is cluster-admin-equivalent by nature. The mitigation is
to treat Argo as a crown-jewel system: strong credentials, no public
exposure, SSO instead of the default `admin` account in a real
environment.

**The etcd encryption key lives on the same node as etcd.** So encryption
at rest protects *snapshots and backups*, not an attacker who owns the
node. Closing that requires a KMS provider with an externally-held key.

**Sealed Secrets does not scale past one engineer.** One person holds a
file that unlocks a public repository's worth of credentials, and holds a
new one every 30 days. It is the right choice *here* because the team size
is one. The intended progression is manual `kubectl` → Sealed Secrets →
External Secrets Operator + AWS Secrets Manager, each step motivated by a
limitation actually encountered.

### Operational

- **Migration tooling ships in the runtime images.** `sequelize-cli` and
  `nodemon` are runtime dependencies because `start:prod` runs migrations.
  Better fix: run migrations in an initContainer, which would also let npm
  be removed from the final image entirely.
- **RabbitMQ is pinned to 3.13**, which is EOL. 4.x silently rejects every
  connection from this app's AMQP client.
- **Node services do not handle `SIGTERM`**, so pod termination is not
  graceful.
- **`update-manifest` uses `ssh-keyscan`** — trust-on-first-use rather
  than a pinned host key.
- **The laptop is on the critical path.** `sonarqube` and `zap-baseline`
  run on the self-hosted `wsl-local` runner, and Sonar's quality gate is
  blocking. Real deployments run runners on always-on infrastructure.

---

## 4. Secrets custody

Three items are **not** in any repository and must not be. Losing any one
of them is unrecoverable.

| Secret | Where | Consequence of loss |
|---|---|---|
| Sealed Secrets private key | `kube-system`, label `sealedsecrets.bitnami.com/sealed-secrets-key=active` | Every SealedSecret in this repo becomes permanently undecryptable |
| etcd encryption config | node, `/var/lib/minikube/certs/enc.yaml` (mode 0600) | Every Secret in etcd becomes unreadable ciphertext |
| Argo CD admin password | — | See the Argo note above: it is a path to everything |

**The sealing key rotates every 30 days** (`--key-renew-period`, default
720h), so a one-time backup is insufficient. Backing it up is a recurring
task.

**Test the backup, do not assume it.** `kubeseal` can decrypt committed
ciphertext offline, without touching the cluster — the same operation
required on a fresh laptop after losing everything:

```bash
kubeseal --recovery-unseal \
  --recovery-private-key <backup.yaml> \
  -f secrets/rabbitmq-credentials.yaml -o yaml
```

Note that recovery *is* disclosure: the plaintext is printed to the
terminal.

`enc.yaml` survives `minikube stop`, but **not** `minikube delete`.

---

## 5. What is not in GitOps

Argo CD syncs this repository, but some things are applied by hand and are
lost on a cluster rebuild. `platform/README.md` has the commands.

- **The Sealed Secrets controller install.** Deliberately excluded: it
  ships the `SealedSecret` CRD, this Application runs with `prune: true`,
  and **pruning a CRD deletes every custom resource of that kind.** One
  Git mistake would destroy all five SealedSecrets.
- **The scoped controller RBAC** (`platform/sealed-secrets-rbac.yaml`)
  *is* Argo-managed — it is small, reviewed, and `selfHeal` actively helps
  keep the upstream cluster-wide binding from creeping back.
- **etcd encryption**: `enc.yaml` on the node plus the
  `--encryption-provider-config` flag in the kube-apiserver static pod.
- **DAST reachability**:
  `docker network connect --alias pitstop.local pitstop-ci minikube`. The
  alias is load-bearing — the Ingress routes on `host: pitstop.local`, so
  without it every ZAP request 404s and the scan reports success having
  tested nothing.

`.gitlab-ci.yml` is excluded from Argo's directory scan
(`exclude: '{argocd/*,.gitlab-ci.yml}'`) because Argo treats every
`.yml`/`.yaml` file it finds as a manifest.

---

## 6. Verifying the controls actually work

Every control below was confirmed by observation, not by a successful
`apply`. This matters more than it sounds: several of them look identical
when working and when silently doing nothing.

| Claim | How it was verified |
|---|---|
| Secrets are encrypted in etcd | `etcdctl get /registry/secrets/... \| strings` → `k8s:enc:aescbc:v1:key1`, no readable values. **Nothing at the kubectl layer reveals this** — decryption is transparent. |
| The key backup works | `kubeseal --recovery-unseal` offline, values matched the live Secret |
| Controller RBAC is scoped | `auth can-i get secrets` → yes for `pitstop`/`kube-system`, **no** for `argocd`/`default`; controller log shows exactly two `Starting informer` lines |
| Sealing round-trips | Deleted the Secret; controller recreated it from the committed SealedSecret in 5s |
| `expired_at` is enforced | Set the date to the past → gate failed on the CVE → notification email arrived |
| The Gitleaks allowlist is not too broad | Sealed files clean, **and** a fake plaintext value planted in `secrets/` was still caught |
| Security headers reach the client | `curl -D -` through the ingress — which also proved express-gateway does not strip response headers |
| `AuthorizationPolicy` actually rejects, not just exists | `kubectl exec` into `vehicle`, `wget` straight to `customer`/`workshop` bypassing `gateway` → `403 Forbidden` from both |
| `PERMISSIVE` carve-out preserves real ingress traffic | Full external path (`ingress-nginx` → `gateway`/`webapp` → backend) still returns `200` after the namespace default flipped to `STRICT` |
| Sidecar injection applied before assuming it did | Pods went from `1/2` to `2/2` only after labeling the namespace **and** rolling each Deployment — the label alone changes nothing for already-running pods |

---

## 7. Traps worth remembering

Each of these produced a green signal that meant something other than
"working".

- **`kubectl rollout status` returns success immediately when the
  Deployment spec has not changed.** It reports on the current spec, not
  the intent behind a change — it will report "successfully rolled out"
  about the old image while Argo has not synced yet.
- **`allow_failure: true` hid a Sonar job that never ran**, and it looked
  identical to passing.
- **`changes:` always evaluates to TRUE in scheduled pipelines.** Without
  a `when: never` guard, a scheduled run would rebuild and push over an
  existing tag — and since running pods keep the image they already
  pulled, `container-scan` would then be scanning something production is
  not running.
- **`GIT_DEPTH: 0` is required for Gitleaks.** GitLab clones shallow by
  default and Gitleaks scans *history*; without it the scan passes because
  it never looked.
- **`include:` resolves at pipeline-creation time.** Retrying a job reuses
  the already-resolved config — a template fix needs a *new* pipeline.
- **`sed` exits 0 whether it replaced everything or nothing**, and its
  anchors silently fail on CRLF files. `update-manifest` greps to verify
  the result rather than trusting the substitution.
- **`list` on Secrets returns full objects including `data`** — it is
  strictly more powerful than `get`. Granting `list` while withholding
  `get` reads as harmless and is not.
- **A "placeholder" value used without editing it becomes the real
  credential.** `terraform-eks/` and `sonarqube/` were originally kept
  outside any Git repository specifically because they hold live
  credentials — a decision documented in `docs/eks.md` and
  `platform/README.md`. A later reorganisation moved them into this
  repository without re-auditing that reasoning, committing
  `terraform.tfstate`/`terraform.tfstate.backup`/`tfplan` (Terraform
  state stores every resource attribute, including passwords, in the
  clear) and a `terraform.tfvars` whose example password string had
  never actually been replaced before `terraform apply` — meaning it
  was simultaneously "obviously a placeholder" and the real RDS master
  password. Fixed by untracking the generated Terraform artefacts,
  replacing `terraform.tfvars` with a committed `.tfvars.example`
  holding no real value, moving the SonarQube Postgres password to an
  environment variable with no default, and gitignoring both patterns
  going forward. The exposed RDS instance no longer exists (see the
  EKS teardown in `docs/eks.md`), so the specific value is moot, but
  the file layout is the actual point: **infrastructure that manages
  secrets belongs outside version control by default, and moving it
  in later is a change that needs the same scrutiny as adding a new
  Secret would get.**
