# 00 - The attacker's view

> What a compromised Pod can learn before it attacks anything: the token
> mounted into it, the Services its environment and DNS name, the API it can
> ask, the kubelet on its node, and every other Pod on a flat network. Then the
> same probes against a Pod that the baseline has hardened, and the one path a
> Pod setting cannot close. This chapter opens Part 05. Each later chapter
> names the path it closes.

**Estimated time:** ~35 min read, ~60 min hands-on (the lab is scripted)

**Prerequisites:**

- [Part 00 ch.04](../00-foundations/04-control-plane-deep-dive.md): the API
  server and the kubelet
- [Part 01 ch.01](../01-core-workloads/01-pods.md#baseline): the baseline this
  chapter attacks, and then applies
- [Part 02 ch.03](../02-networking/03-dns-and-discovery.md): DNS names and the
  search path
- [Part 02 ch.06](../02-networking/06-network-policies.md): NetworkPolicy, used
  in the hardening step

**You'll know after this:**

- list what a Pod learns about its cluster with no exploit: its token, its
  environment and its DNS search path
- read what a ServiceAccount may do with `kubectl auth can-i --list` and a raw
  API call
- tell the kubelet's 401 from its 403, and say what each means to an attacker
- show that a NetworkPolicy denies a connection by making it fail
- name the later Part 05 chapter that closes each path

<!-- tags: security, recon, rbac, networking, foundations, day-2 -->

## Why this exists

A compromised container is not a sealed box. A bug in the application, or a bad
dependency, gives an attacker a shell inside one Pod, and that shell sees the
cluster from the inside. Reconnaissance from there costs nothing and makes no
noise at first. Reading a file, reading the environment, asking DNS for a name
and asking the API what the identity may do are all things the Pod is allowed
to do. Each answer chooses the next move.

[Chapter 02](02-pod-security.md) asked what a root process can do to the node it
runs on. This chapter asks what the attacker learns first, before any escape,
and the baseline answers that too. Most of the reconnaissance needs no
vulnerability. It needs only the defaults Kubernetes ships with. A Pod that
names no ServiceAccount gets a token. A cluster with no NetworkPolicy lets every
Pod reach every other Pod. A kubelet that answers on the node's address answers
every Pod on that node.

The lab makes each default visible, then shows the baseline and two more
controls removing them. It also stops where a Pod's own settings stop, and says
so.

## Mental model

A shell in one Pod has four vantage points, and the lab probes each of them:

- **The Pod itself.** Its user ID, its files, and the token mounted into it.
  The token names the identity the API server will believe.
- **The cluster's names.** Environment variables and DNS records that name
  every Service the Pod can reach. A name is not a secret, but it is a map.
- **The API server.** The same HTTPS API `kubectl` uses, answering whatever
  identity the token names. Discovery is open to every authenticated identity,
  so the map is available too.
- **The network.** The node the Pod runs on and its kubelet, the other Pods on
  the flat Pod network, and, on a cloud, a metadata address that serves node
  identity.

The attacker's aim is the same at each vantage point: find a credential, a
name, or a path the Pod was never meant to have. The defenses sit at different
layers. The baseline removes the token and root from the Pod, a NetworkPolicy
removes paths, and RBAC limits what a token may ask for. None of them removes a
credential the Pod is allowed to use, so the last part of this chapter is about
what remains.

The table below follows the [MITRE ATT&CK Containers matrix][attack-containers],
which maps these steps to technique IDs. The matrix lists Container and Resource
Discovery (T1613), Network Service Discovery (T1046), the Container API as
unsecured credentials (T1552.007), Steal Application Access Token (T1528) and
Application Access Token under lateral movement (T1550.001). The cloud metadata
row uses the enterprise matrix's
[Cloud Instance Metadata API](https://attack.mitre.org/techniques/T1552/005/)
(T1552.005), which the Containers matrix does not list.

## Threats and controls

| Threat | Control this chapter teaches | Where it goes deeper |
|---|---|---|
| A Pod that names no ServiceAccount mounts the default token, and whoever holds it can ask the API (T1552.007, T1528) | `automountServiceAccountToken: false`, and a ServiceAccount of its own | [01.01 baseline](../01-core-workloads/01-pods.md#baseline-service-account); 05.01 for what a token may do |
| A token works from anywhere the API is reachable, and it outlives its Pod for a while (T1550.001) | No token in the Pod at all; a token is refused once its Pod is gone | [05.06 for the API server's token flags](06-control-plane-and-node-hardening.md) |
| Environment variables and DNS name every Service the Pod can reach (T1613, T1046) | `enableServiceLinks: false`; names stay in DNS, so reach is narrowed instead | [02.06](../02-networking/06-network-policies.md) for default-deny; [05.04](04-secrets-and-cluster-hardening.md) for secrets in the environment |
| The kubelet on the node answers every Pod on the network (T1046) | A NetworkPolicy that denies egress to the node's gateway address | [02.06](../02-networking/06-network-policies.md); kubelet flags in [05.06](06-control-plane-and-node-hardening.md) |
| A flat network lets any Pod reach any Service in any namespace (T1046) | Default-deny ingress and egress, with explicit allows selected by label | [02.06](../02-networking/06-network-policies.md); admission rules in [05.07](07-admission-control-and-policy-as-code.md) |
| The default identity holds more rights than its Pod needs (T1613) | Least privilege on every identity, checked with `kubectl auth can-i --list` | [05.01](01-authn-authz-rbac.md) |
| The cloud metadata address serves node identity to any Pod (T1552.005) | Not reachable on kind, so this chapter cites it and does not run it on a cloud | [10.03](../10-cloud-and-managed-kubernetes/03-cloud-identity.md), and [Production notes](#production-notes) below |

Escapes from the container into the node are [chapter 02](02-pod-security.md)'s
subject. Admission policy and runtime detection come later in Part 05. This
chapter stays with reconnaissance.

### Reading the Bookstore's threat model against this lab

The Bookstore keeps a [threat model](../examples/bookstore/THREAT-MODEL.md) with
a row, an ID and a status for each threat
([00.08](../00-foundations/08-security-foundations.md) teaches how to read and
change it). Each step of the lab below attacks one of those rows, so the model
is checked here against a working attack, by hand. No gate reads the file.

| Lab step | Rows it exercises | What the model says today |
|---|---|---|
| Reading the mounted token and calling the API with it | S1, I4, and the Pod-to-API-server boundary TB3 | `review`: the baseline's `automountServiceAccountToken: false` is a field that only a reviewer checks |
| Listing what the default identity may do | I2, E6 | `cluster`: one ServiceAccount and one narrow Role per workload, taught in [05.01](01-authn-authz-rbac.md) |
| Reaching another Pod across namespaces | S3, and the entry point EP8 | `cluster`: default-deny, taught in [02.06](../02-networking/06-network-policies.md) |
| Reaching the kubelet on port 10250 from the Pod | I3, and the entry point EP3 | `cluster`: anonymous kubelet auth off and webhook authorization, in [05.06](06-control-plane-and-node-hardening.md) |

The reading finds the rows whose control is a convention: S1 and I4 rest on a
field in each manifest, and the model marks them `review` because neither
admission nor the static gate rejects a manifest that mounts a token. If a lab
step succeeds against a row marked `baseline` or `cluster`, the row is wrong and
the model changes in the same pull request. Cloud metadata is out of scope in
the model, as it is on kind.

## Diagrams

```text
 compromised Pod
   |
   |-- its files ............ the mounted token: who the API will believe
   |-- its environment ...... one variable per Service in its namespace
   |-- DNS .................. every Service in the cluster, by name
   |-- the API server ....... what that identity may ask for
   |-- default gateway ...... the node, and its kubelet on port 10250
   |-- the Pod network ...... every other Pod, in every namespace
   `-- 169.254.169.254 ...... cloud metadata (no such service on kind)
```

## The attacker's view: a lab on kind

> **Lab 05.00 (tier A).** Recorded on a kind cluster: Kubernetes v1.37.0 node,
> kubectl v1.37.2, containerd v2.3.4. The node reports kernel 7.0.0 on a Linux
> lab host, and the cluster and every Pod ran on that host. The lab cluster is
> named `sf-pilot`, so the captured output shows its node as
> `sf-pilot-control-plane`. A kind cluster you create has its own name. The
> lab's namespaces carry a `p05-` prefix, and the prose names them by role. The
> script is
> [`labs/05-00.sh`](../examples/security-lab/labs/05-00.sh) and the recorded run
> is [`evidence/05-00.txt`](../examples/security-lab/evidence/05-00.txt). The
> attacker's tools come from `curlimages/curl:8.22.0` and the ledger runs
> `busybox:1.36`, both pinned by digest. **Run it only against a kind cluster
> you own.** The script refuses any context that is not `kind-*`, creates three
> `p05-` namespaces, and deletes them at the end. Every probe reads from the
> node or from another Pod. A kind node is itself a container on the machine
> that runs kind, so every escape stays at that node container. Nothing reaches
> the machine that runs kind, and nothing reaches a cloud.

What did not work the first time, shown rather than hidden:

- BusyBox `wget` could not complete a TLS handshake with the kubelet, so the
  lab uses curl. This came from probe runs before the lab was written.
- BusyBox `nslookup` in this image does not apply the search path. In the first
  full run, the short name `ledger.p05-target` returned NXDOMAIN. The lab asks
  for the full name.
- A token still worked for a short time after its Pod was deleted. The probes
  checked again after a minute, and the token was refused.

### Set up the target, a neighbour and the weak app

Three namespaces. `p05-target` holds the ledger, a service the application
should call. `p05-neighbour` is another team's workload. `p05-recon-app` holds
the compromised application, `checkout`. Its namespace enforces `baseline`,
which admits a root Pod that names no ServiceAccount, and warns at `restricted`.
Step 1 creates them:

```sh
kubectl create ns p05-target
kubectl label ns p05-target pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
kubectl create ns p05-neighbour
kubectl label ns p05-neighbour pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
kubectl create ns p05-recon-app
kubectl label ns p05-recon-app pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted
```

The ledger is hardened: the baseline, its own ServiceAccount with the token
switched off, and a Service on port 8080. Save this as `ledger.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ledger-sa
  namespace: p05-target
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: ledger
  namespace: p05-target
  labels:
    app.kubernetes.io/name: ledger
spec:
  serviceAccountName: ledger-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662  # busybox:1.36
      command: ["sh", "-c", "mkdir -p /tmp/www && echo ledger-ok > /tmp/www/index.html && exec httpd -f -p 8080 -h /tmp/www"]
      ports:
        - containerPort: 8080
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ledger
  namespace: p05-target
spec:
  selector:
    app.kubernetes.io/name: ledger
  ports:
    - port: 8080
      targetPort: 8080
```

The neighbour is another team's Pod, hardened the same way. Save it as
`neighbour.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: neighbour-sa
  namespace: p05-neighbour
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: neighbour
  namespace: p05-neighbour
spec:
  serviceAccountName: neighbour-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    runAsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: curlimages/curl@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777  # curlimages/curl:8.22.0
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

The compromised application is `checkout`. Its Service comes first, because a
Service that exists when a Pod starts is written into that Pod's environment.
Save the Service as `checkout-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: checkout
  namespace: p05-recon-app
spec:
  selector:
    app.kubernetes.io/name: checkout
  ports:
    - port: 8080
      targetPort: 8080
```

The weak Pod runs as root, names no ServiceAccount, and sets no other security
field. It is the deliberately insecure form, so its manifest carries the marker
that the gates read. Save it as `checkout-weak.yaml`:

<!-- gate: insecure-on-purpose -->

```yaml
# INSECURE ON PURPOSE: a root Pod that names no ServiceAccount, so it mounts the default token and keeps service links. Lab cluster only.
apiVersion: v1
kind: Pod
metadata:
  name: checkout
  namespace: p05-recon-app
  labels:
    app.kubernetes.io/name: checkout
spec:
  containers:
    - name: app
      image: curlimages/curl@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777  # curlimages/curl:8.22.0
      command: ["sleep", "3600"]
      securityContext:
        runAsUser: 0
```

Apply the four files in order and wait for the Pods (steps 2 and 3):

```sh
kubectl apply -f ledger.yaml
kubectl wait -n p05-target --for=condition=Ready pod/ledger --timeout=180s
kubectl apply -f neighbour.yaml
kubectl wait -n p05-neighbour --for=condition=Ready pod/neighbour --timeout=180s
kubectl apply -f checkout-service.yaml
kubectl apply -f checkout-weak.yaml
kubectl wait -n p05-recon-app --for=condition=Ready pod/checkout --timeout=180s
```

<!-- gate: output -->
```
serviceaccount/ledger-sa created
pod/ledger created
service/ledger created
pod/ledger condition met
serviceaccount/neighbour-sa created
pod/neighbour created
pod/neighbour condition met
# ...
service/checkout created
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), runAsUser=0 (container "app" must not set runAsUser=0), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
pod/checkout created
pod/checkout condition met
```

The `baseline` level admitted the weak Pod. The `restricted` warning lists
what it lacks, and each item is a field the baseline sets:
`allowPrivilegeEscalation`, dropped capabilities, `runAsNonRoot`, a user other
than root and a seccomp profile. Admission said so, and the Pod ran anyway,
because `baseline` does not forbid those fields. This chapter's attacker uses
that gap.

### Recon from inside the Pod

#### Who the Pod is, and what it carries

Step 4 runs from inside `checkout`. It prints the Pod's identity, lists its
token directory, and decodes the payload of the token. A JSON Web Token is three
base64url parts separated by dots, and its middle part is the claims. The lab
rebuilds the padding and decodes it. The signature is never printed.

```sh
kubectl exec -n p05-recon-app checkout -- sh -c '
  id
  ls /var/run/secrets/kubernetes.io/serviceaccount
  T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  P=$(echo "$T" | cut -d. -f2 | tr "_-" "/+")
  while [ $(( ${#P} % 4 )) -ne 0 ]; do P="$P="; done
  J=$(echo "$P" | base64 -d)
  echo "$J" | tr "," "\n" | grep -E "\"(sub|namespace|name)\""
  iat=$(echo "$J" | grep -o "\"iat\":[0-9]*" | cut -d: -f2)
  exp=$(echo "$J" | grep -o "\"exp\":[0-9]*" | cut -d: -f2)
  echo "token lifetime: $((exp - iat)) seconds"'
```

<!-- gate: output -->
```
uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys),4(adm),6(disk),10(wheel),11(floppy),20(dialout),26(tape),27(video)
ca.crt
namespace
token
"kubernetes.io":{"namespace":"p05-recon-app"
"node":{"name":"sf-pilot-control-plane"
"pod":{"name":"checkout"
"serviceaccount":{"name":"default"
"sub":"system:serviceaccount:p05-recon-app:default"}
token lifetime: 31536000 seconds
```

The Pod runs as root, as `runAsUser: 0` asked. Its directory holds three
files: the `token`, the cluster's `ca.crt`, and the `namespace`. The decoded
claims name the Pod, the node it runs on, and the ServiceAccount:
`system:serviceaccount:p05-recon-app:default`. The default ServiceAccount is
the one a Pod gets when it names none. The token's lifetime is 31536000
seconds, which is one year.
[How it works under the hood](#how-it-works-under-the-hood) explains why.

#### The environment: one variable per Service

Step 5 reads the environment. The kubelet writes a host and a port variable for
every Service in the Pod's namespace when the Pod starts.

```sh
kubectl exec -n p05-recon-app checkout -- sh -c 'env | grep -E "_SERVICE_(HOST|PORT)=" | sort'
```

<!-- gate: output -->
```
CHECKOUT_SERVICE_HOST=10.96.196.105
CHECKOUT_SERVICE_PORT=8080
KUBERNETES_SERVICE_HOST=10.96.0.1
KUBERNETES_SERVICE_PORT=443
```

`CHECKOUT_SERVICE_HOST` is the Service this namespace defines. The
`KUBERNETES_SERVICE_*` pair gives the address of the API server's ClusterIP.
Neither variable is a credential. Together they are a map of the namespace, and
the attacker has now read it without a single API call.

#### DNS: the names that exist, and the guesses

Step 6 reads the resolver's search list and asks for two names. The first is a
Service the lab created. The second is a guess the lab made up.

```sh
kubectl exec -n p05-recon-app checkout -- sh -c 'grep "^search" /etc/resolv.conf | cut -d" " -f1-4; grep "^nameserver" /etc/resolv.conf; nslookup ledger.p05-target.svc.cluster.local; nslookup payments.p05-target.svc.cluster.local; echo "payments.p05-target.svc.cluster.local: exit $?"'
```

<!-- gate: output -->
```
search p05-recon-app.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
Server:     10.96.0.10
Address:    10.96.0.10:53

Name:   ledger.p05-target.svc.cluster.local
Address: 10.96.190.243


Server:     10.96.0.10
Address:    10.96.0.10:53

** server can't find payments.p05-target.svc.cluster.local: NXDOMAIN

** server can't find payments.p05-target.svc.cluster.local: NXDOMAIN

payments.p05-target.svc.cluster.local: exit 1
```

The search list starts with the Pod's own namespace, so a short name such as
`ledger` resolves against `p05-recon-app` first. Cluster DNS answers with an
address for a name that exists and says NXDOMAIN for every other name. DNS has
no list of its own, so guessing is the attacker's only enumeration unless the
API will list Services. It will not, for this identity, as step 7 shows.

#### The API: discovery, and what the identity may read

Step 7 calls the API with the token and the cluster CA. It asks for discovery,
which is open to every authenticated identity, and then asks for a list of
Services in another namespace.

```sh
kubectl exec -n p05-recon-app checkout -- sh -c '
  T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  curl -s -o /dev/null -w "discovery: %{http_code}\n" --cacert $CA -H "Authorization: Bearer $T" https://kubernetes.default.svc/apis
  printf "API groups: %s\n" "$(curl -s --cacert $CA -H "Authorization: Bearer $T" https://kubernetes.default.svc/apis | tr "," "\n" | grep -c "\"preferredVersion\"")"
  curl -s -o /dev/null -w "services in p05-target: %{http_code}\n" --cacert $CA -H "Authorization: Bearer $T" https://kubernetes.default.svc/api/v1/namespaces/p05-target/services
  curl -s --cacert $CA -H "Authorization: Bearer $T" https://kubernetes.default.svc/api/v1/namespaces/p05-target/services | tr "," "\n" | grep "\"message\""'
```

<!-- gate: output -->
```
discovery: 200
API groups: 21
services in p05-target: 403
  "message": "services is forbidden: User \"system:serviceaccount:p05-recon-app:default\" cannot list resource \"services\" in API group \"\" in the namespace \"p05-target\""
```

Discovery answered 200 with 21 API groups. The Services list answered 403, and
its message names the identity that asked. The rule that allows discovery is a
default for every authenticated identity, so the map of the API is open to any
token. The rule that refuses the Services list is the default working as
intended. What the default identity may do beyond discovery is the next step's
question.

#### The kubelet, from the Pod's default gateway

Step 8 finds the node. In a kind Pod, the default gateway is the node's bridge
address, so the kubelet on port 10250 is one hop away from every Pod on the
node.

```sh
kubectl exec -n p05-recon-app checkout -- sh -c '
  T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  GW=$(netstat -rn | grep "^0.0.0.0" | tr -s " " | cut -d" " -f2)
  echo "default gateway: $GW"
  curl -sk -o /dev/null -w "anonymous: %{http_code}\n" --max-time 5 https://$GW:10250/pods
  curl -sk -w "\nwith token: %{http_code}\n" --max-time 5 -H "Authorization: Bearer $T" https://$GW:10250/pods'
```

<!-- gate: output -->
```
default gateway: 10.244.0.1
anonymous: 401
Forbidden (user=system:serviceaccount:p05-recon-app:default, verb=get, resource=nodes, subresource(s)=[pods proxy])

with token: 403
```

The `-k` flag skips certificate checking. The kubelet's serving certificate is
not the cluster CA, so there is nothing to check it against. An attacker does
not check it either, and a reader should not copy the flag into anything real.

The two answers mean different things. A 401 says the kubelet refused a request
with no credential. A 403 says the kubelet recognised the token and refused the
request anyway. The kubelet checks the token with the API server, then asks
whether the identity may perform the request, and the 403 body spells out what
it asked for: `get` on `nodes` with the `pods` and `proxy` subresources. The
default identity may not. The attacker now knows the token is valid and what
would have to change for it to read the node's Pods: a grant on the node
subresources, which is a node-level privilege.

#### The metadata address, on kind

Step 9 probes the cloud metadata address from the Pod.

```sh
kubectl exec -n p05-recon-app checkout -- sh -c 'curl -s -o /dev/null --max-time 5 http://169.254.169.254/latest/meta-data/; echo "metadata: exit $?"'
```

<!-- gate: output -->
```
metadata: exit 28
```

Exit code 28 is curl's timeout. Kind has no metadata service, so the address
has no listener. On a cloud node the same address answers, and on AWS the
instance metadata service returns the node's credentials to any process that
can reach it, unless the request is hardened or blocked. The
[AWS instance metadata documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)
describes IMDSv2 and its hop limit. The
[GKE documentation on protecting cluster metadata](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/protecting-cluster-metadata)
describes how metadata concealment keeps Pods away from node credentials. This
lab cannot show either behaviour, and says so. It runs nothing on AWS or GCP.

#### The flat network

Step 10 asks the ledger for its page twice: once from `checkout`, and once from
the neighbour in another namespace.

```sh
kubectl exec -n p05-recon-app checkout -- sh -c 'curl -s --max-time 5 http://ledger.p05-target:8080/'
kubectl exec -n p05-neighbour neighbour -- sh -c 'curl -s --max-time 5 http://ledger.p05-target:8080/'
```

<!-- gate: output -->
```
ledger-ok
ledger-ok
```

Both answered. The cluster network has no policy by default, so a Pod reaches
any Service in any namespace on its port. Nothing here needed a credential.
Short names resolve through the search list in curl, which uses the system
resolver. BusyBox nslookup did not, as the failed first run showed.

### Recon from the network, with the stolen token

The token is a bearer credential. It does not care where it is used. Step 11
copies the token and the cluster CA out of the Pod and builds a kubeconfig on
the workstation that holds only those two things. The kubeconfig must not carry
a client certificate: the workstation's own certificate would authenticate as
the lab's administrator and hide the result.

```sh
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl exec -n p05-recon-app checkout -- cat /var/run/secrets/kubernetes.io/serviceaccount/token > token.txt
kubectl exec -n p05-recon-app checkout -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt > ca.crt
kubectl config set-cluster lab --server="$server" --certificate-authority=ca.crt --embed-certs=true --kubeconfig=stolen.kubeconfig
kubectl config set-credentials stolen --token="$(cat token.txt)" --kubeconfig=stolen.kubeconfig
kubectl config set-context lab --cluster=lab --user=stolen --kubeconfig=stolen.kubeconfig
kubectl config use-context lab --kubeconfig=stolen.kubeconfig
kubectl --kubeconfig=stolen.kubeconfig auth can-i --list -n p05-target
kubectl --kubeconfig=stolen.kubeconfig get services -n p05-target
```

<!-- gate: output -->
```
Cluster "lab" set.
User "stolen" set.
Context "lab" created.
Switched to context "lab".
# ...
Resources                                       Non-Resource URLs                      Resource Names   Verbs
selfsubjectreviews.authentication.k8s.io        []                                     []               [create]
selfsubjectaccessreviews.authorization.k8s.io   []                                     []               [create]
selfsubjectrulesreviews.authorization.k8s.io    []                                     []               [create]
clustertrustbundles.certificates.k8s.io         []                                     []               [get list watch]
# ...
                                                [/version]                             []               [get]
                                                [/version]                             []               [get]
Error from server (Forbidden): services is forbidden: User "system:serviceaccount:p05-recon-app:default" cannot list resource "services" in API group "" in the namespace "p05-target"
```

`kubectl auth can-i --list` asks the API server to list what the caller may do
in a namespace. It is the attacker's rule map, and it comes from the default
cluster roles. Two lines matter here. Discovery is granted to every
authenticated identity, as step 7 showed. The line for
`clustertrustbundles.certificates.k8s.io` is a read grant on a cluster-scoped
resource that this Pod never needed. Reading it is harmless on its own. The
point is that the default identity carries rights nobody reviewed. The
`get services` call then fails with the same 403 the in-Pod probe saw, so the
stolen token is an identity with a short list of rights, which is the outcome
least privilege is supposed to produce.

### Harden: the same Pod, the baseline, and the network

Three things change: the weak Pod goes, the namespace enforces `restricted`, and
a new Pod with the baseline and two NetworkPolicy objects replaces it. Step 12
removes the weak Pod, relabels the namespace, and then offers the weak manifest
again to the admission controller.

```sh
kubectl delete pod checkout -n p05-recon-app --wait=true
kubectl label ns p05-recon-app pod-security.kubernetes.io/enforce=restricted --overwrite
kubectl apply --dry-run=server -f checkout-weak.yaml
```

<!-- gate: output -->
```
pod "checkout" deleted from p05-recon-app namespace
namespace/p05-recon-app labeled
Error from server (Forbidden): error when creating "checkout-weak.yaml": pods "checkout" is forbidden: violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "app" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "app" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "app" must set securityContext.runAsNonRoot=true), runAsUser=0 (container "app" must not set runAsUser=0), seccompProfile (pod or container "app" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

The admission controller refuses the weak Pod with every field it lacks, which
is the same list the warning gave, now as a refusal.
[Chapter 02](02-pod-security.md) shows how `restricted` and the baseline fit
together.

Step 13 applies the NetworkPolicy objects and the hardened Pod. Save the
policies as `policies.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: p05-recon-app
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: checkout-egress
  namespace: p05-recon-app
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: checkout
  policyTypes: ["Egress"]
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: p05-target
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ledger
      ports:
        - { protocol: TCP, port: 8080 }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: p05-target
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ledger-from-checkout
  namespace: p05-target
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: ledger
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: p05-recon-app
          podSelector:
            matchLabels:
              app.kubernetes.io/name: checkout
      ports:
        - { protocol: TCP, port: 8080 }
```

The first object denies everything in `p05-recon-app`. The `checkout-egress`
object then allows the checkout Pod, and only that Pod, to reach kube-dns and to
reach the ledger on port 8080. A flow needs two policies to exist: the caller's
egress and the callee's ingress. The `default-deny` and `ledger-from-checkout`
pair does that for `p05-target`. Each allow selects its peers by namespace label
and Pod label, not by address, so the policy follows the workloads when their IP
addresses change.

Save the hardened Pod as `checkout-hardened.yaml`. It carries the baseline in
full, plus one field the baseline does not list, and it has a ServiceAccount of
its own:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: checkout-sa
  namespace: p05-recon-app
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: checkout
  namespace: p05-recon-app
  labels:
    app.kubernetes.io/name: checkout
spec:
  serviceAccountName: checkout-sa
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    runAsGroup: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: curlimages/curl@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777  # curlimages/curl:8.22.0
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

The ServiceAccount of its own, and `automountServiceAccountToken: false` on
both the ServiceAccount and the Pod, are what the baseline asks for. The
baseline in [01.01](../01-core-workloads/01-pods.md#baseline) asks for those
and explains them. `enableServiceLinks` is the one field here that the
baseline does not list. It controls the per-Service environment variables that
step 5 read. Setting it to `false` stops the kubelet from writing them. It
does not stop DNS, and it does not remove the `KUBERNETES_SERVICE_*` pair in
this run, as step 14 shows.

Apply the policies, the Pod, and wait for it:

```sh
kubectl apply -f policies.yaml
kubectl apply -f checkout-hardened.yaml
kubectl wait -n p05-recon-app --for=condition=Ready pod/checkout --timeout=180s
```

<!-- gate: output -->
```
networkpolicy.networking.k8s.io/default-deny created
networkpolicy.networking.k8s.io/checkout-egress created
networkpolicy.networking.k8s.io/default-deny created
networkpolicy.networking.k8s.io/ledger-from-checkout created
serviceaccount/checkout-sa created
pod/checkout created
pod/checkout condition met
```

### Re-attack

Each probe from the first pass runs again against the hardened Pod, with the
same tools and the same commands. Step 14 checks identity, token and the
environment.

```sh
kubectl exec -n p05-recon-app checkout -- sh -c 'id; test -e /var/run/secrets/kubernetes.io/serviceaccount/token && echo "token: present" || echo "token: absent"; env | grep -E "_SERVICE_(HOST|PORT)=" || echo "service variables: none"'
```

<!-- gate: output -->
```
uid=100(curl_user) gid=101(curl_group) groups=101(curl_group)
token: absent
KUBERNETES_SERVICE_PORT=443
KUBERNETES_SERVICE_HOST=10.96.0.1
```

The Pod runs as UID 100, the curl image's own user. The token file does not
exist. The per-Service variable for `checkout` is gone. The
`KUBERNETES_SERVICE_*` pair is still there, because it is the API server's
address rather than a Service in this namespace. The attacker still learns where
the API server is. Learning the address is cheap, and what matters is whether
the address answers anything useful.

Step 15 checks DNS.

```sh
kubectl exec -n p05-recon-app checkout -- sh -c 'nslookup ledger.p05-target.svc.cluster.local; echo "dns: exit $?"'
```

<!-- gate: output -->
```
Server:     10.96.0.10
Address:    10.96.0.10:53

Name:   ledger.p05-target.svc.cluster.local
Address: 10.96.190.243


dns: exit 0
```

DNS still answers. The allowed path needs it, so the policy keeps the DNS path
open for this Pod. Names remain the attacker's map, and the policy's work is to
keep the paths closed, not to hide the names.

Step 16 checks the kubelet and the API server from the same Pod.

```sh
kubectl exec -n p05-recon-app checkout -- sh -c 'GW=$(netstat -rn | grep "^0.0.0.0" | tr -s " " | cut -d" " -f2); curl -sk -o /dev/null --max-time 5 https://$GW:10250/pods; echo "kubelet: exit $?"; curl -s -o /dev/null --max-time 5 https://kubernetes.default.svc/version; echo "api: exit $?"'
```

<!-- gate: output -->
```
kubelet: exit 28
api: exit 28
```

Both connections time out. The egress policy allows the Pod to reach only
kube-dns and the ledger, so the gateway and the API server's ClusterIP are
refused. The timeouts are the evidence. A NetworkPolicy controller that is not
running lets traffic through, so a denied probe is what proves enforcement is
working. [Chapter 02.06](../02-networking/06-network-policies.md) covers
NetworkPolicy itself.

Step 17 checks the path that the policy allows, and a neighbour that it does
not.

```sh
kubectl exec -n p05-recon-app checkout -- sh -c 'curl -s --max-time 5 http://ledger.p05-target:8080/; echo "ledger from checkout: exit $?"'
kubectl exec -n p05-neighbour neighbour -- sh -c 'curl -s --max-time 5 http://ledger.p05-target:8080/; echo "ledger from neighbour: exit $?"'
```

<!-- gate: output -->
```
ledger-ok
ledger from checkout: exit 0
ledger from neighbour: exit 28
```

The compromised `checkout` still reads the ledger. The policy allows that flow
on purpose, because the application needs it. The neighbour, which the policy
does not allow, is refused. The policy narrowed the paths to the ones the
application needs. It did not make the allowed path safe. An attacker who
controls `checkout` can make the calls `checkout` was allowed to make. Closing
that needs the ledger to check who is calling, and what the caller may ask for.
That is authentication and authorization between services, which
[chapter 01](01-authn-authz-rbac.md) and the service mesh chapter in
[Part 11](../11-advanced-production-patterns/04-service-mesh.md) cover.

Step 18 uses the token stolen in step 11, after the Pod that carried it has been
gone for more than a minute.

```sh
sleep 65
kubectl --kubeconfig=stolen.kubeconfig auth can-i --list -n p05-target
```

<!-- gate: output -->
```
error: You must be logged in to the server (Unauthorized)
```

The API server refuses the token. The Kubernetes documentation on managing
service accounts says that a token whose bound object no longer exists is not
authenticated, and this run shows that. The earlier probe runs showed that the
refusal is not instant: the token still worked for a short time after its Pod
was deleted. That window is why the lab waits, and the chapter does not claim a
number.

## How it works under the hood

### Projected tokens and their lifetime

The kubelet mounts a projected token into every container of a Pod, unless the
Pod sets `automountServiceAccountToken: false`. The token is bound to the Pod:
its claims name the Pod, the node the Pod runs on, and the ServiceAccount, as
step 4 decoded. The
[ServiceAccount admin page](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/)
describes the binding and the rule that a bound object which no longer exists
stops authenticating.

The lifetime is the surprise. This token's `exp` claim is exactly one year
after its `iat`, although the ServiceAccount admin page says a bound token
lasts one hour by default and that the kubelet refreshes it. The
`kube-apiserver`
flag `--service-account-extend-token-expiration` turns on the extension. Its
[reference
entry](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/)
gives the default as `true` and says tokens injected at admission are extended
up to one year. In the v1.37.0 source, the `WithServiceAccounts` option builder
sets `ExtendExpiration` to `true`
([the
source](https://raw.githubusercontent.com/kubernetes/kubernetes/v1.37.0/pkg/kubeapiserver/options/authentication.go)),
and the control plane's options call it through `WithAll()`
([options.go](https://raw.githubusercontent.com/kubernetes/kubernetes/v1.37.0/pkg/controlplane/apiserver/options/options.go)).
The flag exists so that tokens injected at admission keep working while
clients move to bound tokens. A cluster that wants short-lived tokens for
these Pods must set the flag off, and [chapter
05.06](06-control-plane-and-node-hardening.md)
covers the API server flags that bear on it. Until then, a stolen automounted
token is a year-long credential, and the reader's first defense is not to
mount it at all.

### Service environment variables

When the Pod starts, the kubelet writes a host variable and a port variable
for each Service in the Pod's namespace, along with the Docker-links-style
variables that the Service page lists. It also writes the
`KUBERNETES_SERVICE_*` pair for the API server. A Service created after the Pod
starts is not written into it. The
[Service documentation](https://kubernetes.io/docs/concepts/services-networking/service/#environment-variables)
describes the variables and says a Service must exist before the Pod for its
variables to appear. The
[Pod API
reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/pod-v1/#PodSpec)
documents `enableServiceLinks`, which controls the per-Service set. This run
confirms what the field does and does not remove.

### DNS and the search path

Cluster DNS answers a Service at `<service>.<namespace>.svc.cluster.local`.
The Pod's `resolv.conf` carries a search list that starts with its own
namespace, and `ndots:5` means that a name with fewer than five dots is tried
against the search list first. The system resolver, which curl uses, applies
the list. The busybox `nslookup` in this image asked the name as written,
which is why the short name failed in the first run. The
[DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
page shows the `search` list and `options ndots:5`, and
[resolv.conf(5)](https://man7.org/linux/man-pages/man5/resolv.conf.5.html)
defines `ndots`.

### The kubelet's checks

The kubelet serves its API on port 10250, as the
[ports and protocols](https://kubernetes.io/docs/reference/networking/ports-and-protocols/)
page lists. It delegates authentication to the API server with a token review,
and authorization with a subject access review. The
[kubelet authentication and authorization](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/)
page describes the webhook mode and the request attributes it checks. Step 8
is that flow: the token passed authentication, and authorization refused it.

### Flat networks, and what NetworkPolicy checks

A Pod with no policy selecting it accepts traffic from everywhere, and a Pod
with an egress policy is limited to what that policy allows. The
[Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
page states that policies are additive and that a flow needs both sides to
allow it. NetworkPolicy checks which Pods may connect, by label and port. It
does not check what the connection then asks for. That distinction is the
subject of the last section of the re-attack.

## Production notes

On a managed cluster the reconnaissance above works the same way, with two
differences a reader should expect. The first is the metadata address. On AWS
the instance metadata service is reached at `169.254.169.254`, and its hop
limit decides whether a Pod can reach it at all. On GKE, metadata concealment
is the setting that keeps Pods away from node credentials. Both cited
documents are linked in the lab section, and neither was run here. The second
is the NetworkPolicy controller, which depends on the cluster's network
plugin. A plugin that does not enforce policy lets every connection through,
so the denied probes in steps 16 and 17 belong in any cluster's acceptance
test.

Operating these controls on a cloud is the subject of Parts 10, 11, 13, 14,
and 15. Part 05 teaches the mechanism.
[Chapter 10.03](../10-cloud-and-managed-kubernetes/03-cloud-identity.md)
covers how a workload gets cloud identity without a node-wide credential,
which is the design that removes the metadata problem. Service-to-service
authentication is in [Part 11](../11-advanced-production-patterns/04-service-mesh.md).

## Quick Reference

Secure forms only:

```yaml
spec:
  serviceAccountName: checkout-sa
  automountServiceAccountToken: false
  enableServiceLinks: false
```

```sh
kubectl auth can-i --list -n p05-target --as=system:serviceaccount:p05-recon-app:checkout-sa
kubectl get pod checkout -n p05-recon-app -o jsonpath='{.spec.automountServiceAccountToken}'
kubectl get networkpolicy -n p05-recon-app
kubectl exec -n p05-recon-app checkout -- sh -c 'test -e /var/run/secrets/kubernetes.io/serviceaccount/token && echo present || echo absent'
```

## Test your understanding

1. **A Pod names no ServiceAccount and sets no `automountServiceAccountToken`.
   What does an attacker with a shell in it find, which field removes it, and
   what still exists after that field is set?**
   <details><summary>Show answer</summary>

   The token and its `ca.crt` and `namespace` files in
   `/var/run/secrets/kubernetes.io/serviceaccount`, with the Pod's default
   identity. `automountServiceAccountToken: false` on the Pod and on a
   ServiceAccount of its own removes the files. The identity still exists in the
   cluster, with whatever rights RBAC grants it, so the next question is what
   that identity may do, which is chapter 05.01's subject.

   </details>

2. **The kubelet returns 401 to an anonymous request and 403 to the default
   token. Why is the 403 the more useful answer to the attacker?**
   <details><summary>Show answer</summary>

   The 403 means the token is valid and the identity is known: authentication
   passed and authorization refused. The attacker now knows the token works, and
   the 403 body names the subresources it lacks. A 401 would say only that the
   kubelet wants credentials, which the attacker does not have yet.

   </details>

3. **After hardening, the compromised `checkout` still reads the ledger.
   Why does the policy allow it, and what would stop it?**
   <details><summary>Show answer</summary>

   The policy allows the flow because the application needs it. NetworkPolicy
   selects which Pods may connect. It does not check what a connection asks for,
   or who the caller really is beyond its labels. Stopping a compromised allowed
   client needs the ledger to check a caller's identity and rights. That is
   service-to-service authentication and authorization, covered in
   [Part 11](../11-advanced-production-patterns/04-service-mesh.md) and in
   [chapter 01](01-authn-authz-rbac.md).

   </details>

## Further reading

- MITRE ATT&CK, [Containers matrix][attack-containers], and the techniques
  [T1552.007](https://attack.mitre.org/techniques/T1552/007/),
  [T1613](https://attack.mitre.org/techniques/T1613/) and
  [T1552.005](https://attack.mitre.org/techniques/T1552/005/).
- Kubernetes: [Managing service accounts](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/),
  [Configure service accounts for Pods](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/),
  [Service environment variables](https://kubernetes.io/docs/concepts/services-networking/service/#environment-variables),
  [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/),
  [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/),
  [Kubelet authentication and authorization](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/),
  [Ports and protocols](https://kubernetes.io/docs/reference/networking/ports-and-protocols/),
  and [Checking API access](https://kubernetes.io/docs/reference/access-authn-authz/authorization/#checking-api-access).
- The API server option that sets the token extension, in the
  [v1.37.0 source](https://raw.githubusercontent.com/kubernetes/kubernetes/v1.37.0/pkg/kubeapiserver/options/authentication.go).
- AWS: [Use the Instance Metadata Service](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html).
- GKE: [Protecting cluster metadata](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/protecting-cluster-metadata).
- kind: [Quick start](https://kind.sigs.k8s.io/docs/user/quick-start/), for the claim that each kind node is a container.

[attack-containers]: https://attack.mitre.org/matrices/enterprise/containers/
