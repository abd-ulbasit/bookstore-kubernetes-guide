# Part 17 — Running the ML platform on GKE

[Part 12](../12-kubernetes-for-machine-learning/) teaches the ML platform on
Kubernetes: the device-plugin model, Kueue and JobSet, the Kubeflow Training
Operator, KServe, Argo Workflows, and the MLOps maturity ladder. It is 8
chapters and 38,822 words, and it is thorough.

**None of it has been run on a GPU.** Part 17 is where it gets run.

Same rule as [Part 16](../16-gke-in-production-a-to-z/):

> **No chapter is written before its lab has been run, and every command in
> it is pasted from a terminal that executed it.** Each chapter states what
> was run, on which GKE and driver version, what it cost from the billing
> export rather than an estimate, and what did not work first time.

## Prerequisites

**Check GPU quota first, and it may already be enough.** A brand-new project
is often zero, but an established one commonly carries a limit of 1 per
accelerator type per region, which is enough to begin:

```sh
gcloud compute regions describe asia-south1 --format="value(quotas)" | tr ';' '\n' | grep -iE "L4|T4"
```

```
NVIDIA_L4_GPUS               limit 1   usage 0
PREEMPTIBLE_NVIDIA_L4_GPUS   limit 1   usage 0
```

**One L4 covers G1, G2, G3, G5, G6 and G7**, six of the eight labs, including
both of the ones that matter most. Do not assume you are blocked before you
have run the query; the failure mode here is waiting days for a quota you
already had.

**Request an increase only for these two**, and ask early because it is a
review that can take days:

- **G4**, multi-node distributed training, needs 2 or more GPUs. With one you
  can still run a two-worker `PyTorchJob` by time-slicing the single GPU or
  putting one worker on CPU. That demonstrates rendezvous and is explicitly
  **not** distributed training across nodes. Keep the distinction; blurring it
  is the fastest way to lose an ML platform interview.
- **G8** is more interesting with two nodes, though single-node preemption
  still teaches the lesson.

**A warning about the query itself.** If your gcloud token has expired, the
quota command fails, and with stderr suppressed it returns *empty*, which
reads exactly like "no quota". Both the CLI token and ADC expire in about an
hour. Re-authenticate before believing a negative result:

```sh
gcloud auth login && gcloud auth application-default login
```

**Project and identity.** Run these labs in a **dedicated project on a billing
account you control**, and authenticate as a user with `roles/owner` on it
rather than through a service account key.

The temptation is to reuse whatever service-account key is already lying
around, and it is worth resisting for two reasons that bite in different ways.
A key provisioned for one project cannot create resources in another, so you
silently end up billing the wrong account. And a key scoped for an application
workload should never be granted `compute.admin`: those keys tend to live in
`.env` files across several repositories, and widening one turns every copy
into a credential that can spin up GPUs.

**Infrastructure.**
[`examples/gke/terraform/gpu.tf`](../examples/gke/terraform/gpu.tf), a
separate GPU node pool autoscaled **from zero**, so the pool can exist
permanently and cost nothing until a GPU workload lands. Enable with
`enable_gpu_pool = true`. `gpu_max_nodes` defaults to **1** to match the quota
above; raising it without raising quota produces Pending nodes, not more GPUs.
## The cost warning, which is different in kind from Part 16

An L4 node is an order of magnitude more expensive than the `e2-standard-2`
nodes in Part 16. The habits that were merely good practice there are
load-bearing here:

- The pool autoscales to zero. **Verify it actually scaled down** after each
  lab, with `kubectl get nodes` and `gcloud compute instances list`, not by
  assuming.
- `make down` at the end of every session, then `make status` to prove it.
- Spot GPUs are much cheaper and can be reclaimed on 30 seconds notice. That
  is lab G8, not a problem.
- **A forgotten GPU node is the single most expensive mistake available in
  this repository.**

## The chapter and lab plan

Eight labs, each mapping to a Part 12 chapter. Roughly three hours each, and
heavier than Part 16 throughout, because every one of these has a component to
install before it has anything to measure.

| Lab | Part 12 chapter | What you build | What you measure |
|---|---|---|---|
| **G1** | [ch.02 GPUs and accelerators](../12-kubernetes-for-machine-learning/02-gpus-and-accelerators.md) | GPU pool up, drivers installed, `nvidia-smi` in a pod, DCGM exporter scraping | That `nvidia.com/gpu` appears as an allocatable extended resource, and that a pod without a toleration never lands |
| **G2** | ch.02 again | **Time-slicing**: one physical L4 shared by several pods via the device plugin config | How many replicas fit, and what happens to latency when they contend. L4 has no MIG, so this is the sharing story |
| **G3** | [ch.03 batch and gang scheduling](../12-kubernetes-for-machine-learning/03-batch-and-gang-scheduling.md) | **Kueue** with a `ResourceFlavor` and `ClusterQueue` capped below demand, plus **JobSet** | Submit three jobs that need more GPU than the quota allows. Watch two admit and one wait, rather than all three partially placing and deadlocking |
| **G4** | [ch.04 distributed training](../12-kubernetes-for-machine-learning/04-distributed-training.md) | **Kubeflow Training Operator**, a two-worker `PyTorchJob` on a tiny model | Rendezvous actually happening across two pods, and `cleanPodPolicy` behaviour on completion. **This is the closest you will get to distributed training, and it is still not production experience.** Say so |
| **G5** | [ch.06 serving](../12-kubernetes-for-machine-learning/06-model-serving-and-inference.md) | **KServe** `InferenceService` with `scale-to-zero`, then a canary between two model versions | Cold-start latency from zero, and traffic actually splitting by percentage |
| **G6** | ch.06, the heavy one | **vLLM** serving a small LLM. Vary batch size and concurrency under load | **TTFT against throughput.** The central tradeoff in LLM serving, measured by you. Also GPU utilisation while it happens |
| **G7** | [ch.07 pipelines](../12-kubernetes-for-machine-learning/07-ml-pipelines-and-workflows.md) | **Argo Workflows** DAG: train, register the artefact, deploy to KServe | An artefact flowing between steps, and what a failed step does to the DAG |
| **G8** | [ch.08 cost and MLOps](../12-kubernetes-for-machine-learning/08-ml-platform-cost-and-mlops.md) | DCGM metrics into Prometheus. Then **delete a spot GPU node under a running job** | GPU utilisation as a number rather than a feeling, and what preemption does to a training job with and without checkpointing |

**G6 is the one that matters most**, and if you only do three, do G1, G3 and
G6. G6 is the lab that converts "I know LLM serving is memory-bandwidth-bound
on decode" from something you read into something you measured.

**G3 is the most underrated.** Gang scheduling is the difference between an ML
platform and a cluster with GPUs in it, and almost nobody outside the field
can explain why the default scheduler deadlocks a multi-worker job.

## What Part 12 already covers, and the three things it does not

Part 12 is more complete than a quick skim suggests. It already covers MIG and
time-slicing, Kueue and JobSet, the Kubeflow Training Operator, KServe with
Triton and TensorRT, vLLM and continuous batching, Ray, and spot and
preemption handling.

Three gaps, all narrow and all in serving rather than platform:

1. **PagedAttention by name.** Part 12 covers continuous batching; the
   KV-cache-as-virtual-memory mechanism underneath it is not named.
2. **The KV cache as the binding memory constraint.** Why batch size is
   limited by cache growth (sequence length times batch) rather than by model
   weights.
3. **Quantization.** int8 and int4, what they cost in quality and buy in
   memory and throughput.

All three are serving-side LLM specifics that postdate most of the MLOps
canon. Fill them in G6.

## What this Part is evidence of, and what it is not

**Is:** that you have run a GPU scheduler, shared an accelerator, queued jobs
against a quota, served a model with autoscaling, and measured the serving
tradeoff yourself.

**Is not:** production ML operations, distributed training at scale, or a
multi-node GPU cluster. G4 runs two workers on one node pool with a toy model.
That is a rendezvous demonstration, not distributed training, and describing
it otherwise is the fastest way to lose an ML platform loop.
