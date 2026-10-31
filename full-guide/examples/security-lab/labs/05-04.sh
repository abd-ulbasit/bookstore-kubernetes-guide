#!/usr/bin/env bash
# Lab 05.04: secrets at rest and in use. Tier A: kind on a Linux host.
#
# Run this only against kind clusters you own. MODE=all (the default) creates
# one throwaway cluster, lab-secrets, runs steps 1 to 10 on it, and deletes it.
# Steps 1 to 8 need an apiserver flag and a host directory, so they need that
# throwaway cluster. Steps 9 and 10 need neither, so MODE=inuse runs only them,
# in a namespace of their own, on an existing kind cluster named by CLUSTER.
# The script deletes that namespace at the end and never the cluster.
#
# Needs bash, kind, docker and kubectl on the host that runs the kind node.
# The names are lab-secrets (cluster) and secrets-lab (namespace). Set CLUSTER
# and NS to use other names. The recorded run used other names, and its
# transcript says which.
#
# A kind node is a container on the Docker host, not a separate machine, and it
# shares the host's kernel. Every etcd read here runs inside the node, and
# nothing in this script reaches past the node's files and processes. The
# script writes one directory on the Docker host, ENC_DIR, and removes it.
set -u

MODE=${MODE:-all}
CLUSTER=${CLUSTER:-lab-secrets}
NS=${NS:-secrets-lab}
NODE=$CLUSTER-control-plane
# busybox:1.36, pinned by digest (the image 05.02 uses).
BB=busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
# The Kubernetes 1.37.0 node image kind v0.33.0 publishes, pinned by digest.
NODE_IMAGE=kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5

# Read a command from stdin, print it with this run's names, then run it.
run() {
  local cmd
  cmd=$(cat | sed -e "s/lab-secrets/$CLUSTER/g" -e "s/secrets-lab/$NS/g")
  printf '$ %s\n' "$cmd"
  eval "$cmd" 2>&1
  echo
}

work=$(mktemp -d) || exit 1
ENC_DIR=$(mktemp -d "${TMPDIR:-/tmp}/secrets-lab-enc.XXXXXX") || exit 1
cleanup() {
  if [ "$MODE" = all ]; then
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
  else
    kubectl delete namespace "$NS" --ignore-not-found >/dev/null 2>&1
  fi
  rm -rf "$ENC_DIR" "$work"
}
trap cleanup EXIT
cd "$work" || exit 1

case "$MODE" in
  all)
    if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
      echo "refusing to run: a kind cluster named $CLUSTER already exists" >&2
      exit 2
    fi
    ;;
  inuse)
    kubectl config view --raw --flatten --minify --context "kind-$CLUSTER" \
      >kubeconfig 2>/dev/null || { echo "refusing: no kubeconfig context kind-$CLUSTER" >&2; exit 2; }
    export KUBECONFIG="$work/kubeconfig"
    if kubectl get namespace "$NS" >/dev/null 2>&1; then
      echo "refusing to run: namespace $NS already exists" >&2
      exit 2
    fi
    ;;
  *)
    echo "MODE must be all or inuse, not $MODE" >&2
    exit 2
    ;;
esac

# write_config [NAME=KEYFILE ...] writes the EncryptionConfiguration the
# apiserver reloads. The first key encrypts new writes and every key decrypts.
# With no keys, the file holds identity only: the flag is on, nothing is
# encrypted. identity stays last so that plaintext already in etcd still reads.
write_config() {
  local out="$ENC_DIR/encryption-config.yaml.new" pair
  {
    printf '%s\n' 'apiVersion: apiserver.config.k8s.io/v1' 'kind: EncryptionConfiguration' \
      'resources:' '  - resources: ["secrets"]' '    providers:'
    if [ $# -gt 0 ]; then
      printf '%s\n' '      - aesgcm:' '          keys:'
      for pair in "$@"; do
        printf '            - name: %s\n              secret: %s\n' \
          "${pair%%=*}" "$(cat "${pair#*=}")"
      done
    fi
    printf '%s\n' '      - identity: {}'
  } >"$out" && chmod 0600 "$out" && mv "$out" "$ENC_DIR/encryption-config.yaml"
}

# encryption_metrics prints the encryption-config metrics. The reload counters
# appear only after the first reload, and last_config_info names the file
# the apiserver loaded, so a change in either one means a reload happened.
encryption_metrics() {
  kubectl get --raw /metrics | grep '^apiserver_encryption_config_controller' | sort
}

# apply_config [NAME=KEYFILE ...] writes the config and waits for a reload.
apply_config() {
  local before i
  before=$(encryption_metrics)
  write_config "$@" || return 1
  for i in $(seq 1 60); do
    if [ "$(encryption_metrics)" != "$before" ]; then
      echo "apiserver reloaded the encryption config"
      encryption_metrics | cut -c1-160
      return 0
    fi
    sleep 5
  done
  echo "the apiserver did not reload the config within 5 minutes" >&2
  return 1
}

# etcd_ctl runs etcdctl inside the node's etcd container, with the client
# certificates the node already holds.
etcd_ctl() {
  local id
  id=$(docker exec "$NODE" crictl ps -q --label io.kubernetes.container.name=etcd | head -n 1)
  docker exec "$NODE" crictl exec "$id" etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key "$@"
}

# etcd_get NAME prints the raw bytes etcd holds for Secret NAME in $NS.
etcd_get() {
  etcd_ctl get "/registry/secrets/$NS/$1" --print-value-only
}

if [ "$MODE" = all ]; then
export KUBECONFIG="$work/kubeconfig"

echo '## step 1: a throwaway cluster whose apiserver reads an encryption config'
write_config
cat >kind.yaml <<YAML
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER
nodes:
  - role: control-plane
    image: $NODE_IMAGE
    extraMounts:
      - hostPath: $ENC_DIR
        containerPath: /etc/kubernetes/enc
        readOnly: true
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        apiVersion: kubeadm.k8s.io/v1beta4
        timeouts:
          controlPlaneComponentHealthCheck: 15m0s
          kubeletHealthCheck: 15m0s
          kubernetesAPICall: 5m0s
          tlsBootstrap: 15m0s
          discovery: 15m0s
      - |
        kind: ClusterConfiguration
        apiVersion: kubeadm.k8s.io/v1beta4
        apiServer:
          extraArgs:
            - name: encryption-provider-config
              value: /etc/kubernetes/enc/encryption-config.yaml
            - name: encryption-provider-config-automatic-reload
              value: "true"
          extraVolumes:
            - name: encryption
              hostPath: /etc/kubernetes/enc
              mountPath: /etc/kubernetes/enc
              readOnly: true
              pathType: DirectoryOrCreate
YAML
run <<'CMD'
kind version
kind create cluster --name lab-secrets --config kind.yaml --kubeconfig kubeconfig --wait 600s
CMD
run <<'CMD'
kubectl version
kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
docker exec "$NODE" grep -m 4 '^apiVersion' /kind/kubeadm.conf
kubectl -n kube-system get pod -l component=kube-apiserver -o jsonpath='{range .items[0].spec.containers[0].command[*]}{@}{"\n"}{end}' | grep encryption
kubectl get --raw /metrics | grep '^apiserver_encryption_config_controller' | cut -c1-120
etcd_ctl version
CMD

echo '## step 2: a namespace that enforces restricted, and an old Secret'
run <<'CMD'
kubectl create namespace secrets-lab
kubectl label namespace secrets-lab pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted
for i in $(seq 1 60); do kubectl get serviceaccount default -n secrets-lab >/dev/null 2>&1 && break; sleep 1; done
kubectl create secret generic db-credentials -n secrets-lab --from-literal=password=lab-marker-0f3c9a
CMD

echo '## step 3: the API returns the value, because base64 is not encryption'
run <<'CMD'
kubectl get secret db-credentials -n secrets-lab -o jsonpath='{.data.password}'; echo
kubectl get secret db-credentials -n secrets-lab -o jsonpath='{.data.password}' | base64 -d; echo
CMD

echo '## step 4: attack: the same Secret in etcd, read from inside the kind node'
run <<'CMD'
etcd_get db-credentials > db.raw
head -c 4 db.raw | od -An -c
grep -a -o 'lab-marker-[0-9a-f]*' db.raw
CMD

echo '## step 5: enable encryption: an aesgcm key encrypts new writes'
run <<'CMD'
head -c 32 /dev/urandom | base64 | tr -d '\n' >key1
apply_config key1=key1
sed 's/secret: .*/secret: <redacted>/' "$ENC_DIR/encryption-config.yaml"
CMD

echo '## step 6: a new Secret is encrypted; the old one stays plaintext'
run <<'CMD'
kubectl create secret generic new-credentials -n secrets-lab --from-literal=password=lab-new-7e2d41
etcd_get new-credentials > new.raw
grep -a -o 'k8s:enc:[a-z]*:v1:[a-z0-9]*:' new.raw
grep -a -c 'lab-new-7e2d41' new.raw
etcd_get db-credentials > db.raw
grep -a -c 'lab-marker-0f3c9a' db.raw
CMD

echo '## step 7: rewrite every Secret, so each one is encrypted under key1'
run <<'CMD'
kubectl get secrets --all-namespaces -o json | kubectl replace -f - | grep -c replaced
etcd_get db-credentials > db.raw
grep -a -c 'lab-marker-0f3c9a' db.raw
grep -a -o 'k8s:enc:[a-z]*:v1:[a-z0-9]*:' db.raw
CMD

echo '## step 8: rotate. key2 encrypts new writes, key1 still decrypts, then key1 goes'
run <<'CMD'
head -c 32 /dev/urandom | base64 | tr -d '\n' >key2
apply_config key2=key2 key1=key1
kubectl get secrets --all-namespaces -o json | kubectl replace -f - | grep -c replaced
etcd_get db-credentials > db.raw
grep -a -o 'k8s:enc:[a-z]*:v1:[a-z0-9]*:' db.raw
apply_config key2=key2
kubectl get secret db-credentials -n secrets-lab -o jsonpath='{.data.password}' | base64 -d; echo
CMD
fi

echo '## step 9: in use. An environment variable against a mounted file'
cat >app.yaml <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app
  namespace: $NS
automountServiceAccountToken: false
---
apiVersion: v1
kind: Pod
metadata:
  name: app-env
  namespace: $NS
spec:
  serviceAccountName: app
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $BB
      command: ["sleep", "3600"]
      env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: password
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {memory: 64Mi}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
---
apiVersion: v1
kind: Pod
metadata:
  name: app-file
  namespace: $NS
spec:
  serviceAccountName: app
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: $BB
      command: ["sleep", "3600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {memory: 64Mi}
      volumeMounts:
        - name: creds
          mountPath: /etc/creds
          readOnly: true
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /cache
        - name: scratch
          mountPath: /scratch
  volumes:
    - name: creds
      secret:
        secretName: db-credentials
        defaultMode: 0440
        items:
          - key: password
            path: password
    - name: tmp
      emptyDir: {}
    - name: cache
      emptyDir: {}
    - name: scratch
      emptyDir:
        medium: Memory
        sizeLimit: 8Mi
YAML
if [ "$MODE" = inuse ]; then
run <<'CMD'
kubectl create namespace secrets-lab
kubectl label namespace secrets-lab pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted
for i in $(seq 1 60); do kubectl get serviceaccount default -n secrets-lab >/dev/null 2>&1 && break; sleep 1; done
kubectl create secret generic db-credentials -n secrets-lab --from-literal=password=lab-marker-0f3c9a
CMD
fi
run <<'CMD'
kubectl apply -f app.yaml
kubectl wait --for=condition=Ready pod/app-env pod/app-file -n secrets-lab --timeout=180s
kubectl exec -n secrets-lab app-env -- sh -c 'tr "\0" "\n" </proc/1/environ | grep DB_PASSWORD'
kubectl exec -n secrets-lab app-file -- ls -lL /etc/creds/password
kubectl exec -n secrets-lab app-file -- cat /etc/creds/password; echo
kubectl exec -n secrets-lab app-file -- sh -c "grep '/etc/creds ' /proc/mounts | cut -d ' ' -f 3"
CMD
run <<'CMD'
new=$(printf '%s' lab-marker-rotated | base64 | tr -d '\n')
kubectl patch secret db-credentials -n secrets-lab --type merge -p "{\"data\":{\"password\":\"$new\"}}"
for i in $(seq 1 60); do kubectl exec -n secrets-lab app-file -- cat /etc/creds/password 2>/dev/null | grep -q rotated && break; sleep 5; done
kubectl exec -n secrets-lab app-file -- cat /etc/creds/password; echo
kubectl exec -n secrets-lab app-env -- sh -c 'tr "\0" "\n" </proc/1/environ | grep DB_PASSWORD'
CMD

echo '## step 10: where an emptyDir lives on the node'
run <<'CMD'
kubectl exec -n secrets-lab app-file -- sh -c 'cp /etc/creds/password /cache/password && cp /etc/creds/password /scratch/password'
uid=$(kubectl get pod -n secrets-lab app-file -o jsonpath='{.metadata.uid}')
docker exec "$NODE" cat "/var/lib/kubelet/pods/$uid/volumes/kubernetes.io~empty-dir/cache/password"; echo
docker exec "$NODE" stat -f -c '%T %n' "/var/lib/kubelet/pods/$uid/volumes/kubernetes.io~empty-dir/cache" "/var/lib/kubelet/pods/$uid/volumes/kubernetes.io~empty-dir/scratch"
CMD

if [ "$MODE" = all ]; then
  echo '## step 11: delete the throwaway cluster; the trap removes the directories'
  run <<'CMD'
kind delete cluster --name lab-secrets
CMD
else
  echo '## step 11: delete the namespace this run made; the cluster stays'
  run <<'CMD'
kubectl delete namespace secrets-lab
CMD
fi
