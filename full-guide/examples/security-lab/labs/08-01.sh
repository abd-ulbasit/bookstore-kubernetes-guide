#!/usr/bin/env bash
# Lab 08.01: cluster lifecycle. Tier A (kind). Run it only against a kind
# cluster you own, from any directory, with the kubeconfig already pointing at
# that cluster. The worker it drains must not carry a NoSchedule taint for
# other workloads, because the two replicas have to land on it.
#
# It creates one namespace, p08-01-drain (the chapter calls it drain-demo), with
# a default-deny NetworkPolicy, and runs the checks an upgrade starts with: the
# served versions and nodes, a server dry-run that proves a removed apiVersion
# is refused, and a drain of one worker. Two replicas run under a
# PodDisruptionBudget that keeps both up, so the drain is refused and times out.
# The script then uncordons the worker and deletes the namespace.
#
# The kubeadm upgrade and the kind version move are not run here. A version
# move recreates the cluster, so it cannot share one with other labs.
set +e

NS=p08-01-drain
WORKER=lab-worker2
PAUSE=registry.k8s.io/pause@sha256:7031c1b283388d2c2e09b57badb803c05ebed362dc88d84b480cc47f72a21097

# Print a command exactly as it runs, then run it.
run() { printf '$ %s\n' "$1"; eval "$1" 2>&1; echo; }

case "$(kubectl config current-context 2>/dev/null)" in
  kind-*) ;;
  *) echo "refusing: the current context is not a kind cluster"; exit 2 ;;
esac

WORK=$(mktemp -d) || exit 2
cd "$WORK" || exit 2

run 'kubectl version'
run "kubectl get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,UNSCHEDULABLE:.spec.unschedulable"
run "kubectl api-versions | grep -E '^(policy|flowcontrol)' | sort"

cat > namespace.yaml <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: $NS
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
YAML

cat > workload.yaml <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: drain-demo
  namespace: $NS
automountServiceAccountToken: false
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: drain-demo
  namespace: $NS
spec:
  replicas: 2
  selector:
    matchLabels:
      app: drain-demo
  template:
    metadata:
      labels:
        app: drain-demo
    spec:
      serviceAccountName: drain-demo
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65535
        runAsGroup: 65535
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: $PAUSE
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 32Mi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
YAML

cat > pdb.yaml <<YAML
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: drain-demo
  namespace: $NS
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: drain-demo
YAML

run 'kubectl apply -f namespace.yaml'
run 'sed "s#policy/v1\$#policy/v1beta1#" pdb.yaml > pdb-v1beta1.yaml'
run "kubectl apply --dry-run=server -f pdb-v1beta1.yaml"
run "kubectl apply --dry-run=server -f pdb.yaml"
run 'kubectl apply -f workload.yaml'
run 'kubectl apply -f pdb.yaml'
run "kubectl rollout status deployment/drain-demo -n $NS --timeout=180s"
run "kubectl get pods -n $NS -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase"
run "kubectl cordon $WORKER"
run "kubectl drain $WORKER --ignore-daemonsets --delete-emptydir-data --pod-selector app=drain-demo --timeout=45s"
run "kubectl get pdb drain-demo -n $NS"
run "kubectl uncordon $WORKER"
run "kubectl get nodes -o custom-columns=NAME:.metadata.name,UNSCHEDULABLE:.spec.unschedulable"
run "kubectl delete namespace $NS --wait=true"
cd / && rm -rf "$WORK"
