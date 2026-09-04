# GKE lab

A small, destroy-safe GKE cluster for the Part 16 labs. Spin it up, work, tear
it down.

```sh
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in project_id
make up        # plan, confirm, create, and point kubectl at it
../verify.sh   # prove it actually works
make down      # destroy. do this every time you stop
make status    # what exists right now (run this after down, too)
```

## What it creates

Five resources: a VPC, a subnet with secondary ranges for pods and services, a
zonal GKE Standard cluster, a node pool of spot VMs, and an optional budget
alert.

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

**Logging and monitoring trimmed to `SYSTEM_COMPONENTS`.** The default also
ships `WORKLOADS`, and Cloud Logging bills per GiB ingested. A chatty lab
cluster can out-spend its own nodes.

**A budget alerts, it does not cap.** GCP has no hard spend stop. `make down`
is the actual control.

## Cost shape

The management fee is $0.10/cluster/hour, covered by the free-tier credit for
one zonal cluster. Compute is the real variable and bills per second while
nodes exist. Read the node rate from the pricing calculator or from your first
bill rather than trusting an estimate.

## `verify.sh`

Seven checks, each one a claim the guide makes, proven against the real
cluster before the guide makes it: nodes Ready and of the right type, the spot
label, a workload scheduling across both nodes, the Workload Identity metadata
server answering, a PVC binding, and cordon plus drain rescheduling pods. That
last one is the whole reason to leave the single-node k3s box.

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

## Findings from the first executed run

**Executed:** 2026-09-03 · GKE 1.35.7-gke.1027000 · `asia-south1-a` · 2 x
e2-standard-2 spot **Result:** cluster up in ~10 minutes, 9 of 10 checks
passed first time, both failures were defects in this repo rather than in the
cluster. Both are now fixed.

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
produces Pending nodes rather than more GPUs. Second, an L4 node costs an
order of magnitude more than the `e2-standard-2` nodes above, so verify the
pool scaled back to zero after every session rather than assuming it did.
