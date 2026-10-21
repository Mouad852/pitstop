# Volet 5 — Kubernetes on AWS (EKS)

Optional cloud phase, attempted only after Volets 1-4 (CI, GitOps,
pipeline security, observability) and the optional Istio service mesh
phase were already solid on Minikube. Real AWS spend is involved. This
phase runs on a $100 promotional credit (expires 2027-09-02), and a
$20/month AWS Budget alert (80%/100% thresholds) was created before any
billable resource existed.

## Why EKS, and why last

Every other volet was deliberately built against Minikube first, so
mistakes cost time, not money, and manifests could be debugged against a
free, disposable cluster before pointing the same GitOps repository at
one that bills by the hour whether it is used or not. The EKS control
plane costs $0.10/hour (~$73/month) regardless of load, and is not
covered by AWS standard Free Tier at any usage level — it is paid for
here entirely out of the promotional credit.

The goal is narrow: prove that the same `pitstop-kubernetes` repository —
the exact manifests, the exact GitOps flow — reconstructs the running
application on a real cloud Kubernetes distribution, not just on a local
single-node cluster. The cluster is provisioned, verified, and torn down
in one session; it is not meant to run continuously.

## Roadmap

1. Prerequisite tooling (`aws` CLI v2, `eksctl`, `helm`)
2. Dedicated IAM user for provisioning (not root)
3. Region and node sizing decision
4. Cluster provisioning via `eksctl`
5. Re-bootstrap the platform layer (Sealed Secrets, Argo CD, ingress)
6. Point Argo CD at `pitstop-kubernetes`; verify the app end-to-end
7. Immediate teardown
8. Post-teardown orphaned-resource check

## Cost guardrail

An AWS Budget (monthly, fixed, $20, scope: all AWS services) was created
before any resource was provisioned, with email alerts at 80% ($16) and
100% ($20) of the threshold. The $100 promotional credit on this account
explicitly covers Amazon Elastic Container Service for Kubernetes, Amazon
Elastic Compute Cloud, Elastic Load Balancing, and AWS Data Transfer —
every service this phase needs — and expires 2027-09-02.

**Screenshot to capture:** the AWS Budgets page showing this budget and
its two alert thresholds.

---

## Step 1 — Prerequisite tooling ✅

`kubectl` and `helm` were already present from the Minikube phases
(Helm v4.2.4, used for Prometheus/Loki/Istio). Two tools were missing
and installed:

- **`aws` CLI** — Ubuntu's `apt install awscli` packages the deprecated
  CLI v1; AWS's own zip installer was used instead for v2.
- **`eksctl`** — no apt package exists; installed from the official
  GitHub release binary.

Confirmed versions:

| Tool | Version |
|---|---|
| `aws` | 2.36.37 |
| `eksctl` | 0.230.0 |
| `helm` | v4.2.4 |

## Step 2 — Dedicated IAM user for provisioning ✅

Root credentials are never used for CLI/API work, even in a personal
account — root has no permission boundary and its credentials are meant
to stay untouched for account-level tasks only.

Created IAM user `pitstop-eks-provisioner`, API access only (no console
login), policy `AdministratorAccess`. Scoping a minimal custom policy
was considered and rejected: `eksctl` creates CloudFormation stacks,
EC2 instances, VPCs, and IAM roles on its own behalf, and reverse-
engineering the exact permission set is not worth it for a cluster that
exists for one session. The containment comes from the user being
disposable — deleted at teardown — not from a narrow policy.

Configured as a named local profile (`pitstop-eks`, not `default`) so it
is easy to identify and remove independently of any other AWS config on
this machine:

    aws configure --profile pitstop-eks

Verified the resulting identity is the IAM user, not root:

    aws sts get-caller-identity --profile pitstop-eks
    # Arn: arn:aws:iam::<account-id>:user/pitstop-eks-provisioner

## Step 3 — Region and node sizing ✅

**Region: `us-east-1`.** Cheapest and most standard region, best
documented for troubleshooting; no latency-sensitive requirement here.

**Scope: core app only**, not a re-deploy of every optional phase. The
goal of this volet is proving the same GitOps repository reconstructs
the running application on real cloud infrastructure — it does not need
Istio or the Prometheus/Loki stack re-provisioned to demonstrate that.
Smaller footprint means less to provision, less to debug, and less to
remember at teardown.

**Nodes: 2 × `t3.medium`** (2 vCPU / 4 GiB each) in a managed node group.
Sized against the resource-quota ceilings already tuned on Minikube (3
MySQL StatefulSets, RabbitMQ, 5 app Deployments at 2 replicas) — enough
headroom without materially adding to the hourly cost next to the
control plane's $0.10/hr.

**NAT Gateway capped to one, not one-per-AZ.** `eksctl`'s default VPC
creates a NAT Gateway per Availability Zone (typically 2-3), each
~$0.045/hr — redundancy that a single-session cluster does not need.
Set via `vpc.nat.gateway: Single` in the cluster config.

## Step 4, attempt 1 — provisioning via `eksctl` (failed, root cause found)

First attempt used `eksctl create cluster` with `t3.medium` nodes. The
control plane and its addons (`vpc-cni`, `kube-proxy`, `coredns`) created
successfully, but the managed node group stack failed after ~23 minutes
and rolled back:

    Could not launch On-Demand Instances. InvalidParameterCombination -
    The specified instance type is not eligible for Free Tier.

**Root cause: new AWS accounts carry an EC2-level guardrail restricting
launches to Free-Tier-eligible instance types only** — unrelated to
`eksctl` vs. Terraform; the same restriction would have blocked either
tool identically. Found the account's actual eligible list with:

    aws ec2 describe-instance-types \
      --filters "Name=free-tier-eligible,Values=true" \
      --query "InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus,MemoryInfo.SizeInMiB]"

Result was broader than the usual `t2.micro`/`t3.micro` assumption —
**`m7i-flex.large` (2 vCPU / 8 GiB) is Free-Tier-eligible on this
account**, which is *more* capacity than the originally planned
`t3.medium` (2 vCPU / 4 GiB). Switched to it with no other architecture
changes needed. Lesson: check the actual eligible list for the account
before assuming which instance types are off-limits — it is not fixed
across all accounts/regions.

The partially-created cluster (control plane up, no working nodes) was
torn down with `eksctl delete cluster` before rebuilding — a control
plane with nothing attached still bills $0.10/hr.

## Step 4, attempt 2 — Terraform

Switched to Terraform for the actual provisioning. `eksctl` is
EKS-specific tooling; Terraform is the cross-cloud industry standard for
infrastructure-as-code and is asked about far more often in the field.
Used the `terraform-aws-modules/vpc/aws` and `terraform-aws-modules/eks/aws`
community modules rather than hand-built networking — the same reasoning
as Volet 2's choice to use the official Sealed Secrets/Prometheus charts
instead of writing manifests from scratch: real reps in module
composition and state, without reinventing infrastructure that is
already well-tested.

Config lives at `~/pitstop/terraform-eks/` (outside this repository,
same bootstrap-tooling category as `eks-cluster.yaml` and the commands
in `platform/README.md` — one-time provisioning, not an application
manifest). Node instance type corrected to `m7i-flex.large` per the
attempt-1 finding above; NAT Gateway capped to one (`single_nat_gateway
= true`) for the same cost reason as the `eksctl` config.

**`terraform init` initially failed with a git-protocol error, not a
real problem with the modules themselves:**

    fatal: could not read Username for 'https://github.com': terminal
    prompts disabled
    fatal: expected flush after ref listing

Terraform resolves both community modules to a pinned-commit `git
clone` from GitHub under the hood. Plain HTTPS downloads from GitHub
had already worked earlier in this same session (the `eksctl` release
binary) — the failure was specific to `git`'s smart-HTTP protocol,
which uses a different multi-request exchange than a single GET, and
that exchange was getting corrupted somewhere on this machine's network
path. Same class of issue as the DinD MTU black hole documented
elsewhere in this project: environment-specific network framing
corruption, not a credentials or config problem. Fixed by forcing HTTP/1.1
instead of HTTP/2 for git's transport:

    git config --global http.version HTTP/1.1

`terraform init` succeeded immediately after.

`terraform plan` came back clean before anything was applied: **54 to
add, 0 to change, 0 to destroy, no errors.** Notable resources the
modules add by default that were not explicit in the config: a
customer-managed KMS key for envelope-encrypting Kubernetes Secrets
(the same goal as the etcd-encryption-at-rest work done on Minikube,
achieved here through AWS's native mechanism instead of a hand-edited
static pod manifest) and a CloudWatch log group for control-plane
audit/API logs.

`terraform apply tfplan` completed cleanly: **54 added, 0 changed, 0
destroyed.** `kubectl` pointed at the new cluster via:

    aws eks update-kubeconfig --region us-east-1 --name pitstop --profile pitstop-eks

**Screenshot to capture:** `kubectl get nodes` showing the 2 EKS nodes
`Ready`, and/or the EKS console cluster overview page.

## Step 5 — Platform layer bootstrap

**Sealed Secrets was deliberately not reinstalled on this cluster.** The
5 `SealedSecret` objects committed in `secrets/` are encrypted against
the Minikube cluster's specific public key; a fresh controller on EKS
would generate its own key pair and could never decrypt them. Worse,
committing new EKS-specific ciphertext to the same `secrets/` path would
have Minikube's own Argo CD (same repo, same branch, `prune: true`) try
to sync that ciphertext down and overwrite its own working Secrets with
data its controller cannot read — breaking the live Minikube deployment.
Instead, the 5 Secrets were created by hand directly on EKS with fresh
generated values (hex, not base64 — the app builds `amqp://user:pass@host`
directly in code), reusing the exact "hand-made resources are invisible
to Argo's prune tracking" pattern already established for the `pitstop`
namespace itself. This is safe here specifically because the cluster is
short-lived — the original GitOps-hole problem Sealed Secrets solves
does not apply to infrastructure that gets torn down at the end of the
session.

    kubectl create namespace pitstop
    kubectl create secret docker-registry gitlab-registry ...
    kubectl create secret generic mysql-customer-credentials --from-literal=... (× 3, one per service)
    kubectl create secret generic rabbitmq-credentials --from-literal=...

**`ingress-nginx` installed via Helm**, same chart as Minikube, but with
a materially different result: on AWS its `Service` defaults to
`type: LoadBalancer`, which provisions a **real AWS Elastic Load
Balancer** automatically — no `hostPort` trick needed here, unlike
Minikube. This is the same `ingress.yaml` manifest working unchanged
against a completely different implementation underneath it.

    helm install ingress-nginx ingress-nginx/ingress-nginx \
      --namespace ingress-nginx --create-namespace

**Important teardown ordering consequence, noted now so it is not
forgotten later:** that ELB is a real AWS resource that Kubernetes
created, not Terraform — `terraform destroy` has no knowledge of it and
will fail or hang trying to delete the VPC/subnets while the ELB still
holds a network interface inside them. `helm uninstall ingress-nginx`
must run **before** `terraform destroy`, with time to confirm the ELB is
actually gone.

## Step 6 — Argo CD, and two real EKS-specific failures found and fixed

Argo CD installed the same way as Minikube (official manifests, own
namespace), and the same, **unmodified** `argocd/application.yaml`
from this repo was applied directly — it does not hardcode a
destination server, so it targets wherever Argo itself runs with zero
EKS-specific edits.

**Failure 1 — sync failed entirely, not just partially.** This repository
now contains resources from every optional volet (Sealed Secrets,
Prometheus, Istio), committed as plain files with no cluster-specific
filtering. Minikube has every corresponding CRD installed; this
minimal-scope EKS cluster deliberately has none of them. Argo CD fails
an **entire** sync as a unit when any resource's CRD cannot be
discovered — so nothing was created at all, not even the plain
Deployments that had no such problem. Fixed by patching the exclude list
on the **live EKS-only copy** of the Application object (not the
committed file, which stays correct for Minikube):

    kubectl -n argocd patch application pitstop --type merge -p \
      '{"spec":{"source":{"directory":{"exclude":"{argocd/*,.gitlab-ci.yml,platform/*-values.yaml,secrets/*,monitoring/*,istio/*}"}}}}'

**Failure 2 — MySQL/RabbitMQ StatefulSets stuck `Pending` forever, cascading
into `CrashLoopBackOff` on customer/vehicle/workshop.** EKS does not
provision EBS volumes out of the box the way Minikube's built-in
hostPath provisioner just works — the `gp2` StorageClass that exists by
default uses the legacy in-tree AWS EBS provisioner
(`kubernetes.io/aws-ebs`), removed from Kubernetes since 1.23 and
non-functional, and nothing is marked as the cluster's default anyway.
The actual working mechanism, the `aws-ebs-csi-driver` addon, requires
its own IAM role via IRSA. Fixed properly in Terraform rather than an
ad-hoc `kubectl`/`eksctl` fix — new file `storage.tf` builds the IRSA
trust policy (federated trust scoped to exactly one Kubernetes
ServiceAccount, `system:serviceaccount:kube-system:ebs-csi-controller-sa`,
via the OIDC provider Terraform already created in step 4) and attaches
AWS's managed `AmazonEBSCSIDriverPolicy`; `eks.tf` gained a
`cluster_addons.aws-ebs-csi-driver` block wiring the role to the addon.
A `gp3` StorageClass was then created and marked default — **the 4
already-stuck PVCs had to be deleted and let their StatefulSets recreate
them**, since Kubernetes only assigns a default StorageClass to a PVC at
creation time, not retroactively.

`customer`/`vehicle`/`workshop` did not recover automatically once their
databases came up — they had already accumulated 10 `CrashLoopBackOff`
restarts, so Kubernetes' exponential backoff was making them wait
several minutes between attempts. `kubectl rollout restart` forced an
immediate retry instead of waiting it out.

**Verified end-to-end through the real ELB, not just "pods are
Running":**

    curl -H "Host: pitstop.local" http://<elb-hostname>/
    # -> 200
    curl -H "Host: pitstop.local" http://<elb-hostname>/api/customers/ping
    # -> 200

Full chain confirmed working: ELB → `ingress-nginx` → `gateway` →
`customer` → `mysql-customer`, all on infrastructure that did not exist
before this session, built from the same manifests already proven on
Minikube.

**Screenshot to capture:** `kubectl get pods` showing all 14 pods
`Running`, the two `200` responses above, and/or the app loaded in a
browser via the ELB hostname.

## Step 7 — extended AWS tour (beyond the core proof)

Core Volet 5 goal was complete and verified at this point. Continued
deliberately with more AWS services for direct hands-on breadth, not
because the proof required it.

### Terraform remote state (S3 + DynamoDB)

State had been local-only (`terraform.tfstate` on disk) up to this
point — a real gap, since losing that file would lose track of
everything Terraform manages even though the AWS resources would still
exist. Bucket and lock table created via plain `aws` CLI (not
Terraform-managed — a backend cannot be provisioned by the same state
it will then hold, so this is a one-time bootstrap step, same category
as the S3-bucket-adjacent bootstrap commands elsewhere in this project):

    aws s3api create-bucket --bucket pitstop-terraform-state-<account-id> ...
    aws dynamodb create-table --table-name pitstop-terraform-locks ...

`backend "s3" {}` added to `providers.tf`, `terraform init` prompted to
migrate existing local state into it — answered yes, verified with a
clean `terraform plan` (no drift) immediately after.

Noted, not acted on: `dynamodb_table` is now a deprecated backend
parameter in favour of native S3 locking (`use_lockfile = true`), but
still functions correctly and is what most existing real-world
Terraform code still uses — left as-is rather than churn through a
second reconfiguration for no functional gain.

### AWS Load Balancer Controller (real ALB, not just the ingress-nginx ELB)

Same IRSA shape as the EBS CSI driver (`alb-controller.tf`): a role
trusted via the cluster's OIDC provider, scoped to exactly one
ServiceAccount (`system:serviceaccount:kube-system:aws-load-balancer-controller`),
with AWS's officially published IAM policy JSON attached (downloaded
directly, not hand-typed — it is long and specific). Installed via Helm
from the `eks/aws-load-balancer-controller` chart.

**Self-inflicted bug, caught and fixed:** the first `helm install`
command used `$(terraform output -raw)` with no output name argument —
invalid syntax that silently fell through to a `|| echo REPLACE_ME`
fallback already present in the command. The controller was briefly
running with a ServiceAccount IRSA annotation of the literal string
`REPLACE_ME` instead of a real role ARN, meaning it could not
authenticate to AWS at all. Caught by checking the ServiceAccount's
actual annotation directly rather than assuming the install succeeded
just because Helm reported `STATUS: deployed` — Helm reports success
based on the chart applying cleanly, not on whether the values it was
given were meaningful. Fixed with `helm upgrade` supplying the real ARN
(from a newly-added `alb_controller_role_arn` Terraform output) and a
`kubectl rollout restart`, since IRSA credentials are injected into a
pod only at creation time — a ServiceAccount annotation change alone
does not propagate to already-running pods. Verified clean afterward:
controller logs show leader lease acquired and all controllers started
with no `AccessDenied`/`AssumeRole` errors.

A separate, hand-made Ingress (`pitstop-alb`, not committed to Git —
same reasoning as the Secrets) mirrors `ingress.yaml`'s routing with
`ingressClassName: alb` instead of `nginx`. Deliberately verified the
replacement worked before removing the original: a real ALB provisioned
within ~1 minute (`k8s-pitstop-pitstopa-...elb.amazonaws.com`, confirmed
`active` via `aws elbv2 describe-load-balancers`), but initial `curl`
attempts returned `000` — no HTTP response at all.

**Root cause was not the ALB or DNS, both fine within a couple of
minutes** — it was `gateway`'s target group. The controller defaults
every target group's health check to path `/`, expecting `200`.
`gateway` runs `express-gateway`, whose config only defines routes under
`/api/*` — a GET to bare `/` 404s, so `aws elbv2 describe-target-health`
showed `Target.ResponseCodeMismatch: [404]`, unhealthy, and the ALB
correctly refused to route traffic to an unhealthy target (`webapp`
passed the same default check purely by coincidence — its nginx SPA
fallback happens to make `/` a real, working route). Nothing was
actually broken in the running app; the ALB's default assumption just
did not match how `gateway`'s router is structured. Fixed with one
annotation pointing the health check at a route `gateway` actually
serves:

    alb.ingress.kubernetes.io/healthcheck-path: /api/customers/ping

Verified end-to-end through the real ALB after the fix:

    curl -H "Host: pitstop.local" http://<alb-hostname>/          -> 200
    curl -H "Host: pitstop.local" http://<alb-hostname>/api/customers/ping -> 200

`ingress-nginx` and its classic ELB were then uninstalled — no reason to
pay for two load balancers serving the same traffic once the
replacement was proven working, not just installed.

    helm uninstall ingress-nginx -n ingress-nginx

## Step 8 — teardown and the orphaned-resource check

Order matters here, and it is not arbitrary: **anything AWS-managed but
not Terraform-tracked has to be removed manually, before the
infrastructure that makes removing it possible goes away.**

1. **The ALB.** Created by the AWS Load Balancer Controller in response
   to the hand-made `pitstop-alb` Ingress — Terraform has no record of
   it. Deleting the Ingress and uninstalling the controller triggers its
   own cleanup; confirmed gone via `aws elbv2 describe-load-balancers`
   before continuing.
2. **EBS volumes behind the remaining StatefulSets** (`rabbitmq`,
   `mysql-vehicle`, `mysql-workshop` — `mysql-customer` was already
   migrated to RDS). Each was created dynamically by the EBS CSI driver,
   the same way the ALB was created dynamically by its controller —
   Terraform tracks the *driver's IAM role*, never the individual
   volumes it provisions. The `gp3` StorageClass's reclaim policy
   defaults to `Delete`, so deleting the `pitstop` namespace (cascading
   to its PVCs) while the cluster and CSI driver were still alive
   triggered real `DeleteVolume` calls. Verified with `kubectl get pv`
   (empty) and `aws ec2 describe-volumes` filtered to the namespace's
   PVC tag (empty) **before** touching the cluster itself — doing this
   after `terraform destroy` would have left three orphaned, still-
   billing volumes with no cluster left to see them from.
3. **`terraform destroy`.** `terraform plan -destroy` confirmed **63 to
   destroy, 0 to add, 0 to change** first. First actual attempt ran in
   the wrong working directory (`pitstop-kubernetes`, which holds no
   Terraform config) and reported `0 destroyed` — a false "success" with
   nothing actually torn down, caught by checking the shell prompt
   rather than trusting the exit message. Re-run from
   `~/pitstop/terraform-eks`: **63 destroyed, 0 errors.**
4. **Orphaned-resource sweep**, checked directly against AWS rather than
   trusted from the destroy log: `aws eks list-clusters`, `rds
   describe-db-instances`, `elbv2 describe-load-balancers`, `ec2
   describe-volumes`, `ec2 describe-addresses` (Elastic IPs — the NAT
   gateway holds one), and `ec2 describe-nat-gateways` all came back
   empty. Nothing survived outside Terraform's own bookkeeping.
5. **The S3 state bucket and DynamoDB lock table.** Bootstrap resources
   Terraform's own state can never contain, by construction — a backend
   cannot track the storage it depends on to exist. Safe to remove only
   now that `destroy` has fully finished, since it needed this backend
   to track its own progress while running. DynamoDB deleted cleanly in
   one call. **S3 needed an extra step**: the backend's bucket has
   versioning enabled (Terraform's default for its own state bucket), so
   `aws s3 rm --recursive` only added delete markers on top of the
   existing version history rather than actually emptying the bucket —
   `delete-bucket` failed with `BucketNotEmpty` until every object
   *version* and every *delete marker* were purged explicitly via
   `list-object-versions` + `delete-objects`. Confirmed fully gone via a
   final `list-buckets`/`list-tables` sweep, independent of the delete
   commands' own reported success.

**Left in place, deliberately, not an oversight:** the
`pitstop-eks-provisioner` IAM user. It costs nothing sitting unused and
removing it needs a root-account console action rather than its own
(now nonexistent) credentials — an optional last step, not a required
one.

**Final state:** every resource this phase created — EKS cluster, node
group, VPC/NAT/EIPs, RDS instance, ALB, EBS volumes, IAM roles, the
Terraform state backend — is gone, verified directly against AWS rather
than assumed from tool output. Volet 5 is complete.

### RDS — moving one service off in-cluster MySQL

Scoped to `customer` only, as a demonstration of the pattern rather than
a full migration of all three data stores — `vehicle` and `workshop`
staying on their in-cluster `StatefulSet`s is a deliberate scope cut,
not an oversight.

Provisioned via a new `rds.tf`: a `db.t3.micro` MySQL 8.4.11 instance
(matching the `mysql:8.4` image the in-cluster `StatefulSet`s already
run), `publicly_accessible = false`, reachable only on 3306 from a
security group scoped to `module.eks.node_security_group_id` — the same
least-privilege instinct as the mesh `AuthorizationPolicy` work, enforced
here at the AWS network layer instead. `skip_final_snapshot = true` and
`backup_retention_period = 0` since this is throwaway session data, not
worth protecting from `terraform destroy`.

**The cutover reused the same DNS trick, not a ConfigMap edit.**
`customer`'s `PROD_DB_HOSTNAME` is `mysql-customer`, committed in
`services/customer.yaml` and therefore shared with Minikube — editing it
directly would have pointed Minikube's `customer` at an AWS RDS endpoint
it cannot reach, and would need reverting by hand at every future sync.
Instead, `infrastructure/mysql-customer.yaml` (the `StatefulSet` and its
two `Service`s) was added to the **live EKS-only** Application's
`exclude` pattern, and a hand-made `type: ExternalName` `Service`, still
named `mysql-customer`, was applied in its place — pointing that same
in-cluster DNS name at the RDS endpoint instead of a pod. Nothing in
`customer.yaml` changed at all; the app's config and code are identical
across both clusters.

**Discovered by accident: excluding a path from a `prune: true`
Application deletes its live resources immediately, not just on the next
manual sync.** The plan was to patch the exclude pattern first, then
delete the `StatefulSet`/`Service`s by hand. The manual deletes returned
`NotFound` — Argo CD had already pruned them itself the moment the patch
landed, reconciling within seconds rather than waiting for its ~3-minute
poll interval. Convenient here, but worth knowing as a general fact about
`selfHeal`+`prune`: removing a path from what Argo watches is treated
identically to deleting those resources from Git.

**Second self-inflicted bug, caught by verification rather than assumed
away:** the Secret holding the new RDS password was created with a
literal placeholder string still in it, a copy/paste slip. The two
already-running `customer` pods kept returning `200` on
`/api/customers/ping` throughout — which looked healthy but proved
nothing, since that route never touches the database at all. The actual
failure only surfaced in the new pod's logs, from the `sequelize-cli
db:migrate` step that runs before the server starts listening:

    ERROR: Access denied for user 'pitstop'@'...' (using password: YES)

Fixed by re-creating the Secret with the password read directly out of
`terraform.tfvars` (`grep | cut`) instead of retyped by hand, removing
the transcription step that caused the mismatch.

**Verified with a real write, not just a healthy pod:**

    curl http://<alb-hostname>/api/customers/all   # -> []
    curl -X POST .../api/customers/add -d '{...}'  # -> added
    curl http://<alb-hostname>/api/customers/all
    # -> [{"id":1,...,"email":"rds-test@example.com",...}]

The first pod to start ran the actual `create-customer` migration
against a fresh, empty RDS schema; the second, starting seconds later,
correctly reported "already up to date" — confirming both replicas share
one RDS database rather than each independently reaching some other
state, and that authentication, schema migration, and row persistence
all worked against infrastructure outside the Kubernetes cluster
entirely.

**Screenshot to capture:** the RDS console showing the `pitstop-customer`
instance (engine, class, "Available" status), and/or the three `curl`
outputs above showing the row appearing after the write.
