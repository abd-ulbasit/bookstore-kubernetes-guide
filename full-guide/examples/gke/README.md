# GKE lab

A small, destroy-safe GKE cluster for the Part 16 labs. Spin it up, work, tear
it down.

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars  # set project_id, authorized_cidrs
make up        # plan, confirm, apply THAT saved plan, point kubectl at it
../verify.sh   # prove it actually works
make down      # destroy. do this every time you stop
make status    # what exists right now (run this after down, too)
```

## What it creates

A VPC, a subnet with secondary ranges for pods and services, a zonal GKE
Standard cluster, a node pool of spot VMs, a dedicated node service account
with two project role bindings, and an optional budget alert. Cloud NAT is
created only when `private_nodes` is set.

## Decisions that are load-bearing

**Zonal, not regional.** The GKE free-tier credit ($74.40/month per billing
account) covers one zonal or Autopilot cluster's management fee. It is
explicitly not applied to a regional cluster's fee, so going regional turns a
free control plane into roughly $73/month.

**`deletion_protection = false`.** The google provider defaults this to true,
and the provider schema says so directly: *"When the field is set to true or
unset in Terraform state, a terraform apply or terraform destroy that would
delete the cluster will fail."* Without this line the teardown half of
spin-up-and-tear-down does not work, and you discover it at teardown.

**Default node pool removed, managed pool added.** Changing node config on the
default pool forces a cluster replacement. A separate pool means node changes
are node changes.

**Spot nodes.** Much cheaper, reclaimable on 30 seconds notice. Handling
preemption is a lab.

**A dedicated node service account.** Nodes run as `<cluster_name>-nodes`.
It holds only `roles/container.defaultNodeServiceAccount` (write logs and
metrics, list metric descriptors and time series) and
`roles/artifactregistry.reader`, not the Compute Engine default service
account, which in most projects holds Editor on the whole project. The
`cloud-platform` OAuth scope stays: scopes are a legacy filter, and Google's
guidance is a broad scope plus a minimal IAM account. Workloads get their
own permissions through Workload Identity. Applying this needs permission to
create service accounts and grant project roles (Owner has both), and the
IAM and Cloud Resource Manager APIs enabled (see Prerequisites). On an
existing lab it replaces the node pools, which is a `make down`/`make up`
anyway. One gap is left on purpose: the throwaway default pool, which exists
for a few minutes while the cluster is created, still boots on the default
service account, because changing that means setting `node_config` on the
cluster resource, and the provider marks that block ForceNew. *Added after
the 2026-09-03 run below; the earlier code ran on the default compute SA
while its comment said "least privilege". Applied and verified on
2026-11-04 (nodes run as `<cluster_name>-nodes`).*

**`make up` applies the plan it showed you.** `make plan` saves the plan to
`tfplan`, and `make up` applies that file after you type `yes`. It used to
run a second, unsaved `apply -auto-approve`, which planned again after you
had approved the first plan.

**Regular channel with a 1.37 floor.** On 2026-10-26 GKE added
1.37.1-gke.1552000 to the Regular channel but kept 1.36.4 as the default for
new clusters. `min_master_version` asks for 1.37 anyway. It is a minimum,
not a pin: the channel still auto-upgrades the cluster past it. *Added after
the 2026-09-03 run below. Applied and verified on 2026-11-04 (control plane
1.37.1-gke.1552000).*

**Logging and monitoring trimmed to `SYSTEM_COMPONENTS`.** The default also
ships `WORKLOADS`, and Cloud Logging bills per GiB ingested. A chatty lab
cluster can out-spend its own nodes. The price is that your own pods' stdout
never reaches Cloud Logging: on 2026-11-04 a test pod's log line showed in
`kubectl logs` and not in `gcloud logging read`. Use `kubectl logs`, or add
`WORKLOADS` back for a lab that needs it.

**The public API endpoint is limited to your address.** A GKE control plane
has a public IP, and by default it accepts connections from the whole
internet and from every Google Cloud public IP. An unauthenticated curl
against a default cluster got 200 from `/healthz` and `/livez` and 401 from
`/version` and `/api`: credentials still gate it, but it is reachable.
`authorized_cidrs` is required and has no default, and
`gcp_public_cidrs_access_enabled = false` closes the Google Cloud door.
Google documents that nodes and pods reach the control plane over internal
addresses, so this does not cut them off. Use your own address as a `/32`.
If it changes you lose `kubectl` until you run the command below; Terraform
and gcloud talk to the GKE API, not the cluster API, so they keep working.
Teardown needs the variable too: with a `terraform.tfvars` from before this
change, `make down` stops on the missing `authorized_cidrs`, so add your
address first, or delete the cluster by name with `make nuke`.

```sh
gcloud container clusters update <cluster_name> --zone <zone> \
  --enable-master-authorized-networks --master-authorized-networks=<ip>/32
```

Google's hardening guide offers a different route, which is to switch the
public endpoint off and use the DNS endpoint. It is not tried here. *Added
after the 2026-11-04 tests and applied to the running lab that night: an
in-place update of about 9 minutes, after which `kubectl` from the listed
address and all of `verify.sh` still worked.*

**No new bindings to the catch-all groups.** `rbac_binding_config` refuses
RBAC bindings whose subject is `system:authenticated` (on GKE that includes
anyone with a Google account), `system:unauthenticated` or
`system:anonymous`. It needs GKE 1.30.1-gke.1283000 or later, leaves
Kubernetes' own default bindings alone, and does not remove a non-default
binding that already exists. A scan of the lab cluster found none, so the
default was exposure and not an open hole. No lab in this guide creates such
a binding. *Added after the 2026-11-04 tests and applied in the same
in-place update.*

**Opt-ins that stay off.** Each is a variable that defaults to off, and with
it off the configuration is unchanged.

- `private_nodes` removes the nodes' public IPs and adds Cloud NAT
  ([`nat.tf`](terraform/nat.tf)). Google says private nodes need Cloud NAT
  to pull from an external registry, and `verify.sh` pulls from Docker Hub.
  Cloud NAT lists at $0.0014 per VM per hour, $0.005 per hour per external
  IP and $0.045 per GiB processed (up to 32 VMs): for two nodes and one IP
  that is $0.0078 per hour, about $5.62 per 720 hours, plus data. The public
  node IPs are not open today: probes from the internet to both nodes on
  ports 22, 10250, 10255 and 30080 timed out. This is the Part 16 chapter 09
  exercise.
- `secrets_kms_key` encrypts Kubernetes Secrets with a Cloud KMS key you
  create. GKE already encrypts them at rest by default; this adds
  application-layer encryption under your key. It needs the Cloud KMS API
  and a key ring in the cluster's region, and the GKE service agent needs
  `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key. Google's worked
  example prices software key versions at $0.06 per month and key
  operations at $0.03 per 10,000.
- `enable_binauthz` turns on Binary Authorization in project-singleton
  enforce mode. It lists at $0.01613 per cluster per hour (around $12 a
  month, against a $12 monthly free-tier credit per billing account), and
  the default project policy allows every image, so it enforces nothing
  until you write a policy. That is Part 16 chapter 13.

*Added after the 2026-11-04 run. None of the three has been applied or
planned; the configuration passes `terraform validate` and no more.*

**Vulnerability scanning is not part of this lab.** GKE's own workload
vulnerability scanning was removed (the standard tier shut down on
2025-07-31, and a deprecated tier cannot be enabled on a cluster), so there is
nothing to switch on in Terraform. Image scanning is Artifact Analysis at
$0.26 per scan.

**A budget alerts, it does not cap.** GCP has no hard spend stop. `make down`
is the actual control. The budget counts spend before credits
(`credit_types_treatment = "EXCLUDE_ALL_CREDITS"`). The default nets credits
off, so on a free-trial or promotional credit the lab reads as $0 and no
alert ever fires while the credit drains. The budget filter takes the project
number, not the project ID, so `budget.tf` looks the number up; given the ID,
a plan showed the filter as changed with no edit to the config. *Both added
on 2026-11-04; after the lookup the next plan showed no change to the
budget.*

**The cluster waits for the grants and the budget.** It `depends_on` the
node role grants and the budget, so if either fails the apply stops before
anything bills. *Added after the 2026-11-04 run and validated, not applied:
the lab was being torn down by then.*

## Cost shape

The management fee is $0.10/cluster/hour, covered by the free-tier credit for
one zonal cluster. Compute is the real variable and bills per second while
nodes exist. Read the node rate from the pricing calculator or from your first
bill rather than trusting an estimate.

## `verify.sh`

Eight sections and twelve checks, each one a claim the guide makes, proven
against the real cluster before the guide makes it: nodes Ready and of the
right type, the spot label, a workload scheduling across both nodes, the
Workload Identity metadata server answering as the Workload Identity pool (a
node service account in that answer fails the check), a PVC binding, cordon
plus drain rescheduling pods, and a default-deny NetworkPolicy blocking
traffic. The drain is the whole reason to leave a single-node local cluster.

Nothing runs in `default` or as root. The test workloads run in two
namespaces, `verify-lab` and `verify-netpol`, both at the `restricted` Pod
Security level, as non-root with every capability dropped, and the cleanup
step deletes both. It waits for `verify-lab`, so the PVC is gone before you
tear down; the CSI driver deletes the disk after that, and a disk left behind
keeps billing, so `make status` after `make down` is still the check. The
NetworkPolicy check exists
for a cluster without Dataplane V2, where a policy applies cleanly and
blocks nothing. It has only been run against a Dataplane V2 cluster, where
the client got 200 before the policy and no answer after it.

## Prerequisites, learned the hard way

**`gke-gcloud-auth-plugin` must be installed AND on PATH.** Without it
`kubectl` fails with `executable gke-gcloud-auth-plugin not found` immediately
after `get-credentials` reports success, which is a confusing pair of
messages. Install it with `gcloud components install gke-gcloud-auth-plugin`.
There is no Homebrew formula for it.

On a Homebrew-installed SDK the component lands in
`/opt/homebrew/share/google-cloud-sdk/bin`, which is **not** on PATH even
though `gcloud` itself is symlinked into `/opt/homebrew/bin`. So installing it
is not enough:

```sh
export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"
```

**Enable the APIs before the first apply.** The lab project did not have
the Cloud Resource Manager API on, and the role grants need it. On
2026-11-04 the first apply created the cluster in about 8 minutes, then
failed on the node role grants with "Cloud Resource Manager API has not been
used in project ... or it is disabled", so the node pool was never created.
Enabling it and applying again finished the stack. The cluster now waits for
those grants, but enable the APIs first anyway:

```sh
gcloud services enable container.googleapis.com iam.googleapis.com \
  cloudresourcemanager.googleapis.com billingbudgets.googleapis.com
```

**Terraform needs credentials that can refresh.** If `gcloud auth
application-default print-access-token` fails with a reauthentication error,
ADC is stale and cannot re-prompt in a non-interactive shell. Either run
`gcloud auth application-default login`, or hand the provider the CLI token
directly:

```sh
export GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)"
```

That token expires in about an hour, which is fine for one lab session and not
for a long apply.

**The project's `default` network is open.** The lab project still had
Google's `default` network with `default-allow-ssh` (tcp:22) and
`default-allow-rdp` (tcp:3389) open to 0.0.0.0/0, plus `default-allow-icmp`.
The lab uses its own VPC and nothing runs on `default`, so nothing here
reaches it, but in a throwaway project delete those rules:

```sh
gcloud compute firewall-rules delete default-allow-ssh default-allow-rdp
```

**Default-deny egress also takes away Workload Identity.** With a
default-deny Egress policy (`podSelector: {}`), a pod's request to the
metadata server for its service account email timed out. After an egress
rule to `169.254.169.254/32` on TCP 80 it answered `<project>.svc.id.goog`
with HTTP 200, so that rule is the one proven necessary on Dataplane V2.
Google's network-policy page lists `169.254.169.254/32` on ports 80 and 8080
for Dataplane V2, and `169.254.169.252/32` on ports 988 and 987 for GKE
1.21.0-gke.1000 and later; the test above had `169.254.169.252/32` on 988
allowed as well, and 988 alone was not tried. Google also warns that without
these rules you may see disruptions during auto-upgrades. Part 05's
default-deny egress needs the exception wherever a pod uses Workload
Identity.

## kube-bench on GKE

Pin `docker.io/aquasec/kube-bench:v0.16.0` and `--benchmark gke-1.9.0`, never
`:latest`; the upstream `job-gke.yaml` uses `:latest`. Run it with
`--targets node,policies,managedservices` in a namespace labelled
`pod-security.kubernetes.io/enforce=privileged` for the Job only, then delete
the Job and restore the label.

Only the node checks (3.1.1 to 3.1.4, all PASS here) are reliable from the
stock Job. The policies and managedservices results are not evidence: the
image has no `gcloud`, so 5.1.1, 5.2.1 and 5.6.7 fail for tool reasons
(5.2.1 also needs `PROJECT_ID`, `CLUSTER_NAME` and `LOCATION`), and the Job's
default ServiceAccount cannot call the API, which is probably why 4.3.2
reported PASS with only two namespaces holding NetworkPolicies. The whole run
reported 15 PASS, 4 FAIL and 38 WARN, and the managedservices WARNs are
"run this gcloud command". Check those with `gcloud container clusters
describe`.

## Findings from the 2026-11-04 run

**Executed:** 2026-11-03 22:12 to 23:54 UTC (2026-11-04 in UTC+5) · GKE
1.37.1-gke.1552000 on control plane and nodes · Dataplane V2 ·
`asia-south1-a` · 2 x e2-standard-2 Spot, containerd 2.4.1 on
Container-Optimized OS **Result:** `verify.sh` passed 11 of 11 on the first
build and 12 of 12 after the hardening below. The GKE steps in Part 10 ran
against the same cluster, and each chapter labels what ran.

**Cost:** about $0.16 for the nodes, their disks and their IPs (2.97 Spot
node-hours at the Mumbai list price of $0.0483 per e2-standard-2 hour), at
most $0.06 for two test load balancers that lived under an hour (the
catalog's minimum forwarding-rule charge is $0.03 an hour), and under $0.01
for the throwaway default pool. The management fee for 1.71 cluster-hours is
$0.17, which the free-tier credit covers if no other zonal cluster on the
billing account uses it. These are resource-hours times billing-catalog
prices, not a bill, which lags by about a day.

**1. The budget would never have alerted.** `credit_types_treatment`
defaults to counting spend after credits. On a project paid from a free-trial
or promotional credit the lab nets to $0, so no threshold is ever crossed
while the credit drains. Fixed: the budget counts spend before credits.

**2. A first apply on a fresh project half-applied.** The cluster was created
and the node role grants then failed because the Cloud Resource Manager API
was off, so there was a cluster with no node pool. It is the 2026-09-03
ordering hazard again: the cluster came first and the thing that failed came
after it. Fixed twice: the API is a listed prerequisite, and the cluster
`depends_on` the grants and the budget.

**3. NetworkPolicy had nothing enforcing it.** The Terraform set no dataplane
and no network policy enforcement, and Google's network policy page says a
Standard cluster enforces policies only with one of the two. Every policy
from Part 05 would have applied cleanly and blocked nothing. Found by reading
the config; the old config was not run to show it. Fixed: Dataplane V2 at
create, and `verify.sh` section 7 now proves a default-deny blocks traffic.
On Dataplane V2 the enforcer is the `anetd` DaemonSet, so a check that greps
for `calico` finds nothing.

**4. Secure Boot was off.** Shielded nodes are on by default and Secure Boot
is not. Fixed; the node pool reported `enableSecureBoot: true`.

**5. The API server answered the whole internet.** With no authorized
networks, an unauthenticated curl from outside got 200 from `/healthz` and
`/livez` and 401 from `/version` and `/api`, and every Google Cloud public IP
was allowed as well. Fixed with a required `authorized_cidrs`, applied to the
running lab in place.

**6. New bindings to `system:authenticated` were allowed.** A scan found none,
so this was exposure, not a hole. Fixed with `rbac_binding_config`, applied in
the same update.

**7. Two `verify.sh` checks proved less than they said.** The Workload
Identity check accepted `iam.gserviceaccount.com` in the answer, which is the
node service account leak it exists to catch (found by reading; the mode was
not switched off to show it). The workloads ran in `default` as root. Fixed:
only the pool identity passes, and everything runs non-root in `restricted`
namespaces.

**8. Two defaults hide things.** A pod's stdout never reached Cloud Logging,
because this lab trims logging to `SYSTEM_COMPONENTS` (see above). Reading a
Secret left no audit entry at all: GKE writes Admin Activity logs, which
record changes, and Data Access logs were off on the project. Chapter 10.01
now says who-read-this-Secret needs Data Access logs turned on first.

## Findings from the first executed run

**Executed:** 2026-09-03 · GKE 1.35.7-gke.1027000 (from that run's notes;
the project's audit log has the create and delete calls but no version) ·
`asia-south1-a` · 2 x e2-standard-2 spot **Result:** cluster up in ~10
minutes, 9 of 10 checks passed first time. The failed check and a failed
budget apply were both defects in this repo rather than in the cluster. Both
are now fixed.

**1. The budget resource failed after the cluster was already created.**
`google_billing_budget` calls `billingbudgets.googleapis.com`, which rejects
user credentials carrying no quota project. The cluster applied fine and the
budget did not, leaving a half-applied stack with a live bill and no budget
alert on it. Fixed by adding `user_project_override = true` and
`billing_project` to the provider. Note the ordering hazard: the thing that
guards your spend is the thing that failed, and it failed *after* the spend
started.

**2. The PVC check asserted the wrong thing.** GKE's default StorageClass
`standard-rwo` is `WaitForFirstConsumer`, so a PVC with no pod stays `Pending`
deliberately: provisioning waits until the scheduler picks a node so the disk
is created in the right zone. The original check called that a failure. It was
the check that was wrong, not the cluster. Now verified properly by attaching
a consumer pod, writing a file, and reading it back.

**Also observed and worth a chapter:** nodes came up with public external IPs
(two ephemeral public addresses). That is the default for a non-private
cluster and it is not what you want in production. Private clusters plus Cloud
NAT is chapter 09 of Part 16.

**Verified working:** two Ready nodes of the requested type, the
`cloud.google.com/gke-spot=true` label, a 4-replica Deployment spreading
across both nodes, the Workload Identity metadata server answering as
`<PROJECT_ID>.svc.id.goog` rather than exposing the node service account, PD
CSI provisioning with a real read-write round trip, and cordon plus drain
rescheduling every pod off a node with all 4 replicas staying Ready.

## The GPU pool

[`terraform/gpu.tf`](terraform/gpu.tf) adds a separate GPU node pool for the
[Part 17](../../17-ml-platform-on-gke/) ML platform labs. It is **off by
default** (`enable_gpu_pool = false`) and **autoscales from zero**, so the
pool can exist permanently and cost nothing until a GPU workload lands.

`g2-standard-4` carries one NVIDIA L4 (24 GB), which is the cheapest GCP GPU
that serves a 7B model at fp16 with room for a KV cache. **L4 does not support
MIG**, so the GPU-sharing lab uses time-slicing rather than partitioning; A100
and H100 are the MIG-capable parts.

Two things before you enable it. **Check your GPU quota first**, because it
caps what can actually schedule:

```sh
gcloud compute regions describe asia-south1 --format="value(quotas)" | tr ';' '\n' | grep -i L4
```

A brand-new project is often zero; an established one frequently has 1.
`gpu_max_nodes` defaults to 1 to match that, and raising it above quota
produces Pending nodes rather than more GPUs. Second, a `g2-standard-4` L4
node lists at roughly 8 to 9 times an `e2-standard-2` node above (Mumbai,
checked 2026-11-04), so verify the pool scaled back to zero after every
session rather than assuming it did.
