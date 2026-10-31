#!/usr/bin/env bash
# Lab 03.02: Secrets. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. It creates one namespace, p03-02-secrets, applies the chapter's
# Secret, RBAC and Pod steps in it, and deletes the namespace at the end. The
# chapter names the bookstore namespace; this script applies the same files
# with only the namespace replaced.
#
# The db-credentials value is generated when the script starts. The script
# writes it into 16-db-credentials.yaml in place of the demo literal, and never
# prints it. Checks compare hashes, lengths and key names instead.
set +e

K="${KUBECTL:-kubectl}"
NS=p03-02-secrets
MANI=examples/bookstore/raw-manifests
SA="system:serviceaccount:$NS"

ctx=$("$K" config current-context 2>/dev/null)
case "$ctx" in
  kind-*) ;;
  *) echo "refusing to run: kubectl context '$ctx' is not a kind cluster" >&2; exit 2 ;;
esac

# Print a command the way a reader would type it, then run it.
show() { printf '$ %s\n' "$*"; }

echo "## step 0: versions and a clean start"
show "kubectl version"
"$K" version 2>&1 | grep -E 'Client Version|Server Version'
show "kubectl get namespace $NS"
"$K" get namespace "$NS" 2>&1
echo

echo "## step 1: a namespace that enforces restricted, and three ServiceAccounts"
show "kubectl create namespace $NS"
"$K" create namespace "$NS"
show "kubectl label namespace $NS pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted"
"$K" label namespace "$NS" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
show "kubectl apply -f -   # three ServiceAccounts in $NS; none mounts a token"
"$K" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: secret-reader
  namespace: $NS
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: secret-lister
  namespace: $NS
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-creator
  namespace: $NS
automountServiceAccountToken: false
EOF
echo

echo "## step 2: the db-credentials Secret, with a value generated now"
PW="$(openssl rand -hex 16)"
show 'PW=$(openssl rand -hex 16)   # generated now, never printed'
show "sed -e 's/devpassword/\$PW/' -e 's/namespace: bookstore/namespace: $NS/' $MANI/16-db-credentials.yaml | kubectl apply -f -"
sed -e "s/devpassword/$PW/" -e "s/namespace: bookstore/namespace: $NS/" "$MANI/16-db-credentials.yaml" | "$K" apply -f - 2>&1
show "kubectl get secret db-credentials -n $NS -o jsonpath='{.data.POSTGRES_DB}'; echo"
"$K" get secret db-credentials -n "$NS" -o jsonpath='{.data.POSTGRES_DB}'; echo
show "kubectl get secret db-credentials -n $NS -o jsonpath='{.data.POSTGRES_DB}' | base64 -d; echo"
"$K" get secret db-credentials -n "$NS" -o jsonpath='{.data.POSTGRES_DB}' | base64 -d; echo
show "kubectl get secret db-credentials -n $NS -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d | wc -c | tr -d ' '"
"$K" get secret db-credentials -n "$NS" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d | wc -c | tr -d ' '
show 'decoded POSTGRES_PASSWORD equals $PW (compared, not printed)'
if [ "$("$K" get secret db-credentials -n "$NS" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)" = "$PW" ]; then echo yes; else echo no; fi
show "kubectl get secret db-credentials -n $NS -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | grep -c stringData"
"$K" get secret db-credentials -n "$NS" -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | grep -c stringData
show "kubectl get secret db-credentials -n $NS -o jsonpath='{...last-applied-configuration}' | grep -c \"\$PW\"   # the generated value, counted not printed"
"$K" get secret db-credentials -n "$NS" -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' | grep -c "$PW"
show "grep -n 'password=\$(POSTGRES_PASSWORD)' $MANI/10-catalog-deploy.yaml $MANI/14-orders-deploy.yaml"
grep -n 'password=\$(POSTGRES_PASSWORD)' "$MANI/10-catalog-deploy.yaml" "$MANI/14-orders-deploy.yaml" 2>&1
echo

echo "## step 3: RBAC on one named Secret: get is named, list and create are not"
show "kubectl apply -f -   # Role db-credentials-reader and its RoleBinding in $NS"
"$K" apply -f - 2>&1 <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: db-credentials-reader
  namespace: $NS
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["db-credentials"]
    verbs: ["get", "list", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: db-credentials-reader
  namespace: $NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: db-credentials-reader
subjects:
  - kind: ServiceAccount
    name: secret-reader
    namespace: $NS
EOF
for q in "get secret/db-credentials" "get secret/other-creds" "get secrets" "list secrets" "create secrets"; do
  show "kubectl auth can-i $q -n $NS --as=$SA:secret-reader"
  "$K" auth can-i $q -n "$NS" --as="$SA:secret-reader" 2>&1
done
show "kubectl get secrets -n $NS --as=$SA:secret-reader -o name"
"$K" get secrets -n "$NS" --as="$SA:secret-reader" -o name 2>&1
show "kubectl get secrets -n $NS --as=$SA:secret-reader --field-selector metadata.name=db-credentials -o name"
"$K" get secrets -n "$NS" --as="$SA:secret-reader" --field-selector metadata.name=db-credentials -o name 2>&1
show "kubectl create secret generic extra -n $NS --from-literal=k=v --as=$SA:secret-reader"
"$K" create secret generic extra -n "$NS" --from-literal=k=v --as="$SA:secret-reader" 2>&1
echo

echo "## step 4: a list with no names returns every value"
show "kubectl apply -f -   # Role secret-lister (list secrets, no names) and its RoleBinding in $NS"
"$K" apply -f - 2>&1 <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-lister
  namespace: $NS
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: secret-lister
  namespace: $NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: secret-lister
subjects:
  - kind: ServiceAccount
    name: secret-lister
    namespace: $NS
EOF
show "kubectl get secrets -n $NS --as=$SA:secret-lister -o json | grep -o '\"POSTGRES_[A-Z]*\"' | sort -u"
"$K" get secrets -n "$NS" --as="$SA:secret-lister" -o json 2>&1 | grep -o '"POSTGRES_[A-Z]*"' | sort -u
echo

echo "## step 5: a Pod that may only create Pods reads the Secret"
show "kubectl apply -f -   # Role pod-creator (create pods) and its RoleBinding in $NS"
"$K" apply -f - 2>&1 <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-creator
  namespace: $NS
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-creator
  namespace: $NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pod-creator
subjects:
  - kind: ServiceAccount
    name: pod-creator
    namespace: $NS
EOF
show "kubectl auth can-i create pods -n $NS --as=$SA:pod-creator"
"$K" auth can-i create pods -n "$NS" --as="$SA:pod-creator" 2>&1
show "kubectl auth can-i get secrets -n $NS --as=$SA:pod-creator"
"$K" auth can-i get secrets -n "$NS" --as="$SA:pod-creator" 2>&1
show "kubectl apply -f -   # secret-reveal: runs as pod-creator, mounts db-credentials, prints checksums"
"$K" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: secret-reveal
  namespace: $NS
spec:
  serviceAccountName: pod-creator
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox:1.36@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 # busybox:1.36
      command: ["sh", "-c", "sha256sum /creds/POSTGRES_PASSWORD; ls /creds"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
      volumeMounts:
        - name: creds
          mountPath: /creds
          readOnly: true
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: creds
      secret:
        secretName: db-credentials
    - name: tmp
      emptyDir:
        sizeLimit: 16Mi
EOF
show "kubectl wait pod/secret-reveal -n $NS --for='jsonpath={.status.phase}=Succeeded' --timeout=300s"
"$K" wait pod/secret-reveal -n "$NS" --for='jsonpath={.status.phase}=Succeeded' --timeout=300s 2>&1
show "kubectl logs secret-reveal -n $NS"
"$K" logs secret-reveal -n "$NS" 2>&1
PW_SHA="$(printf '%s' "$PW" | shasum -a 256 | cut -d' ' -f1)"
show 'the first checksum equals the checksum of $PW (compared, not printed)'
if [ "$("$K" logs secret-reveal -n "$NS" | head -1 | cut -d' ' -f1)" = "$PW_SHA" ]; then echo yes; else echo no; fi
show "kubectl delete pod secret-reveal -n $NS --now"
"$K" delete pod secret-reveal -n "$NS" --now 2>&1
echo

echo "## step 6: the Secret as files, and the mode an inspection Pod sees"
show "kubectl apply -f -   # secret-files: runs as secret-reader, mounts db-credentials with defaultMode 0440 and fsGroup 65532"
"$K" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: secret-files
  namespace: $NS
spec:
  serviceAccountName: secret-reader
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: busybox:1.36@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662 # busybox:1.36
      command:
        - sh
        - -c
        - |
          id
          ls -lnL /etc/creds
          grep ' /etc/creds ' /proc/mounts
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { memory: 64Mi }
      volumeMounts:
        - name: creds
          mountPath: /etc/creds
          readOnly: true
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: creds
      secret:
        secretName: db-credentials
        defaultMode: 0440
    - name: tmp
      emptyDir:
        sizeLimit: 16Mi
EOF
show "kubectl wait pod/secret-files -n $NS --for='jsonpath={.status.phase}=Succeeded' --timeout=300s"
"$K" wait pod/secret-files -n "$NS" --for='jsonpath={.status.phase}=Succeeded' --timeout=300s 2>&1
show "kubectl logs secret-files -n $NS"
"$K" logs secret-files -n "$NS" 2>&1
show "kubectl delete pod secret-files -n $NS --now"
"$K" delete pod secret-files -n "$NS" --now 2>&1
echo

echo "## step 7: an immutable Secret refuses an in-place change"
TOK="$(openssl rand -hex 16)"
show "kubectl apply -f -   # immutable-demo: Secret with immutable: true, value generated now"
"$K" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: immutable-demo
  namespace: $NS
type: Opaque
immutable: true
stringData:
  token: "$TOK"
EOF
show "kubectl get secret immutable-demo -n $NS -o jsonpath='{.immutable}'; echo"
"$K" get secret immutable-demo -n "$NS" -o jsonpath='{.immutable}'; echo
show "kubectl patch secret immutable-demo -n $NS --type merge -p \"{\\\"stringData\\\":{\\\"token\\\":\\\"\$(openssl rand -hex 16)\\\"}}\""
"$K" patch secret immutable-demo -n "$NS" --type merge -p "{\"stringData\":{\"token\":\"$(openssl rand -hex 16)\"}}" 2>&1
show "kubectl delete secret immutable-demo -n $NS"
"$K" delete secret immutable-demo -n "$NS" 2>&1
echo

echo "## step 8: gitleaks over the raw manifests (CI pin v8.30.1)"
show "gitleaks version"
gitleaks version 2>&1
show "gitleaks dir --config ../.gitleaks.toml --no-banner --no-color --redact $MANI"
gitleaks dir --config ../.gitleaks.toml --no-banner --no-color --redact "$MANI" 2>&1
echo

echo "## step 9: clean up"
show "kubectl delete namespace $NS --wait=true"
"$K" delete namespace "$NS" --wait=true 2>&1
