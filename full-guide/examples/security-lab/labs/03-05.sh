#!/usr/bin/env bash
# Lab 03.05: stateful data patterns. Tier A (kind).
#
# Run this ONLY against a kind cluster you own, from the guide's full-guide/
# directory. It creates one namespace, p03-05-stateful, runs the Bookstore's
# Postgres StatefulSet (examples/bookstore/raw-manifests/20-) and a restore
# Pod in it, and deletes the namespace at the end. The chapter names the
# bookstore namespace; this script applies the same files with only the
# namespace replaced.
#
# The snapshot CRDs are not installed on this cluster. The VolumeSnapshot
# steps record the refusal and create nothing. The restore Pod runs on a PVC
# made without dataSource, so the Pod spec is the chapter's and the PVC is not.
# The restore Pod reads a scratch Secret, db-credentials-restore, made from the
# same manifest with only its name changed. The shared db-credentials Secret,
# which postgres-0 and the apps read, is never patched.
# Generated secret values are never printed.
set +e

K="${KUBECTL:-kubectl}"
PY="${PY:-python3}"
NS=p03-05-stateful
MANI=examples/bookstore/raw-manifests
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

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
show "kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}'"
"$K" get nodes -o jsonpath='{.items[*].status.nodeInfo.kubeletVersion}'; echo
show "kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.containerRuntimeVersion}'"
"$K" get nodes -o jsonpath='{.items[*].status.nodeInfo.containerRuntimeVersion}'; echo
show "kubectl get namespace $NS"
"$K" get namespace "$NS" 2>&1
echo

echo "## step 1: a namespace that enforces restricted"
show "kubectl create namespace $NS"
"$K" create namespace "$NS"
show "kubectl label namespace $NS pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted"
"$K" label namespace "$NS" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
echo

echo "## step 2: the ServiceAccounts and the database Secrets"
show "sed 's/namespace: bookstore/namespace: $NS/' $MANI/05-serviceaccounts-rbac.yaml | kubectl apply -f -"
sed "s/namespace: bookstore/namespace: $NS/" "$MANI/05-serviceaccounts-rbac.yaml" | "$K" apply -f - 2>&1
show "sed 's/namespace: bookstore/namespace: $NS/' $MANI/16-db-credentials.yaml | kubectl apply -f -"
sed "s/namespace: bookstore/namespace: $NS/" "$MANI/16-db-credentials.yaml" | "$K" apply -f - 2>&1
show "sed -e 's/name: db-credentials\$/name: db-credentials-restore/' -e 's/namespace: bookstore/namespace: $NS/' $MANI/16-db-credentials.yaml | kubectl apply -f -"
sed -e 's/name: db-credentials$/name: db-credentials-restore/' -e "s/namespace: bookstore/namespace: $NS/" "$MANI/16-db-credentials.yaml" | "$K" apply -f - 2>&1
echo

echo "## step 3: the Postgres StatefulSet under restricted"
show "sed 's/namespace: bookstore/namespace: $NS/' $MANI/20-postgres-statefulset.yaml | kubectl apply -f -"
sed "s/namespace: bookstore/namespace: $NS/" "$MANI/20-postgres-statefulset.yaml" | "$K" apply -f - 2>&1
show "kubectl rollout status statefulset/postgres -n $NS --timeout=900s"
"$K" rollout status statefulset/postgres -n "$NS" --timeout=900s 2>&1
show "kubectl get pod postgres-0 -n $NS"
"$K" get pod postgres-0 -n "$NS" 2>&1
show "kubectl get pod postgres-0 -n $NS -o jsonpath='{.spec.serviceAccountName}{\" automount=\"}{.spec.automountServiceAccountToken}'"
"$K" get pod postgres-0 -n "$NS" -o jsonpath='{.spec.serviceAccountName}{" automount="}{.spec.automountServiceAccountToken}'; echo
show "kubectl get pod postgres-0 -n $NS -o jsonpath='{.spec.securityContext}'"
"$K" get pod postgres-0 -n "$NS" -o jsonpath='{.spec.securityContext}'; echo
show "kubectl get pod postgres-0 -n $NS -o jsonpath='{.spec.containers[0].securityContext}'"
"$K" get pod postgres-0 -n "$NS" -o jsonpath='{.spec.containers[0].securityContext}'; echo
echo

echo "## step 4: the root filesystem is read-only, the emptyDir is not"
inner='touch /usr/local/bin/x; echo "exit=$?"; touch /tmp/x && echo "tmp: writable"'
show "kubectl exec -n $NS postgres-0 -- sh -c '$inner'"
"$K" exec -n "$NS" postgres-0 -- sh -c "$inner" 2>&1
inner='env | cut -d= -f1 | grep -E "^(POSTGRES_|PGDATA)" | sort'
show "kubectl exec -n $NS postgres-0 -- sh -c '$inner'"
"$K" exec -n "$NS" postgres-0 -- sh -c "$inner" 2>&1
inner='psql -U bookstore -d bookstore -tAc "select 1"'
show "kubectl exec -n $NS postgres-0 -- sh -c '$inner'"
"$K" exec -n "$NS" postgres-0 -- sh -c "$inner" 2>&1
echo

echo "## step 5: a narrow Role for the snapshot job, and the refusals"
show "kubectl apply -f -   # ServiceAccount, Role and RoleBinding, namespace $NS"
"$K" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: snapshot-job
  namespace: $NS
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: snapshotter
  namespace: $NS
rules:
  - apiGroups: ["snapshot.storage.k8s.io"]
    resources: ["volumesnapshots"]
    verbs: ["get", "list", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: snapshot-job
  namespace: $NS
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: snapshotter
subjects:
  - kind: ServiceAccount
    name: snapshot-job
    namespace: $NS
EOF
show "kubectl get --raw /apis/snapshot.storage.k8s.io/v1/namespaces/$NS/volumesnapshots --as=system:serviceaccount:$NS:postgres-sa"
"$K" get --raw "/apis/snapshot.storage.k8s.io/v1/namespaces/$NS/volumesnapshots" --as=system:serviceaccount:$NS:postgres-sa 2>&1
show "kubectl get --raw /apis/snapshot.storage.k8s.io/v1/namespaces/$NS/volumesnapshots --as=system:serviceaccount:$NS:snapshot-job"
"$K" get --raw "/apis/snapshot.storage.k8s.io/v1/namespaces/$NS/volumesnapshots" --as=system:serviceaccount:$NS:snapshot-job 2>&1
echo

echo "## step 6: the VolumeSnapshotClass and VolumeSnapshot, on a cluster without the CRDs"
show "kubectl apply -f - < examples/bookstore/raw-manifests/18-postgres-snapshot.yaml   # namespace set to $NS"
sed "s/namespace: bookstore/namespace: $NS/" "$MANI/18-postgres-snapshot.yaml" > "$DIR/18.yaml"
"$K" apply -f - 2>&1 < "$DIR/18.yaml"
show "kubectl get volumesnapshot -n $NS"
"$K" get volumesnapshot -n "$NS" 2>&1
echo

echo "## step 7: the restore PVC, first with dataSource, then without"
show "kubectl apply -f -   # restore PVC with dataSource, namespace $NS"
"$K" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-postgres-restore
  namespace: $NS
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
  dataSource:
    name: postgres-snap-0
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF
show "kubectl get pvc data-postgres-restore -n $NS"
"$K" get pvc data-postgres-restore -n "$NS" 2>&1
show "kubectl delete pvc data-postgres-restore -n $NS --ignore-not-found"
"$K" delete pvc data-postgres-restore -n "$NS" --ignore-not-found 2>&1
show "kubectl apply -f -   # the same PVC without dataSource, a control for the Pending claim"
"$K" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-postgres-restore
  namespace: $NS
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
EOF
show "kubectl get pvc data-postgres-restore -n $NS"
"$K" get pvc data-postgres-restore -n "$NS" 2>&1
show "kubectl describe pvc data-postgres-restore -n $NS | sed -n '/^Events:/,\$p'"
"$K" describe pvc data-postgres-restore -n "$NS" 2>&1 | sed -n '/^Events:/,$p'
echo

echo "## step 8: the restore Pod, under restricted, with the password from a file"
show "kubectl apply -f -   # restore Pod, namespace $NS"
"$K" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: postgres-restore
  namespace: $NS
  labels:
    app: postgres-restore
    app.kubernetes.io/part-of: bookstore
spec:
  serviceAccountName: postgres-sa
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    runAsGroup: 999
    fsGroup: 999
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: postgres
      image: postgres@sha256:1beaa3084eee2676f20a9cd9928f0bf2c5bf674f8e49f81017912183d377c61c  # postgres:16
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      env:
        - name: POSTGRES_USER
          value: bookstore
        - name: POSTGRES_DB
          value: bookstore
        - name: POSTGRES_PASSWORD_FILE
          value: /run/secrets/db/password
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
      readinessProbe:
        exec:
          command: ["pg_isready", "-h", "/var/run/postgresql", "-U", "bookstore", "-d", "bookstore"]
        periodSeconds: 5
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          memory: 512Mi
      volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
        - name: run
          mountPath: /var/run/postgresql
        - name: tmp
          mountPath: /tmp
        - name: db-password
          mountPath: /run/secrets/db
          readOnly: true
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data-postgres-restore
    - name: run
      emptyDir:
        sizeLimit: 8Mi
    - name: tmp
      emptyDir:
        sizeLimit: 32Mi
    - name: db-password
      secret:
        secretName: db-credentials-restore
        defaultMode: 0440
        items:
          - key: POSTGRES_PASSWORD
            path: password
EOF
show "kubectl wait --for=condition=Ready pod/postgres-restore -n $NS --timeout=900s"
"$K" wait --for=condition=Ready pod/postgres-restore -n "$NS" --timeout=900s 2>&1
show "kubectl get pod postgres-restore -n $NS"
"$K" get pod postgres-restore -n "$NS" 2>&1
show "kubectl get pvc data-postgres-restore -n $NS"
"$K" get pvc data-postgres-restore -n "$NS" 2>&1
inner='id; ls -l /run/secrets/db/; touch /run/secrets/db/x; echo "exit=$?"'
show "kubectl exec -n $NS postgres-restore -- sh -c '$inner'"
"$K" exec -n "$NS" postgres-restore -- sh -c "$inner" 2>&1
echo

echo "## step 9: the database keeps the password it was initialised with; a Secret change is not applied"
# The stock pg_hba.conf trusts loopback, so the password checks below connect to
# the Pod's own address, which the scram-sha-256 rule governs. The address is
# replaced when the command runs and redacted in what is printed.
POD_IP=$("$K" get pod postgres-restore -n "$NS" -o jsonpath='{.status.podIP}')
redact() { sed "s/$POD_IP/<pod-ip>/g"; }
inner='grep -v "^#" /var/lib/postgresql/data/pgdata/pg_hba.conf | grep .'
show "kubectl exec -n $NS postgres-restore -- sh -c '$inner'"
"$K" exec -n "$NS" postgres-restore -- sh -c "$inner" 2>&1
inner='PGPASSWORD="$(cat /run/secrets/db/password)" psql -h <pod-ip> -U bookstore -d bookstore -tAc "select 1"'
show "kubectl exec -n $NS postgres-restore -- sh -c '$inner'"
"$K" exec -n "$NS" postgres-restore -- sh -c "${inner//<pod-ip>/$POD_IP}" 2>&1 | redact
# Ready only proves the socket answers. Wait here until the server accepts TCP.
deadline=$((SECONDS + 300))
until "$K" exec -n "$NS" postgres-restore -- sh -c "pg_isready -h $POD_IP -p 5432" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then break; fi
  sleep 5
done
inner='pg_isready -h <pod-ip> -p 5432'
show "kubectl exec -n $NS postgres-restore -- sh -c '$inner'"
"$K" exec -n "$NS" postgres-restore -- sh -c "${inner//<pod-ip>/$POD_IP}" 2>&1 | redact
inner='PGPASSWORD="$(cat /run/secrets/db/password)" psql -h <pod-ip> -U bookstore -d bookstore -tAc "select 1"'
show "kubectl exec -n $NS postgres-restore -- sh -c '$inner'"
"$K" exec -n "$NS" postgres-restore -- sh -c "${inner//<pod-ip>/$POD_IP}" 2>&1 | redact
# The value is read into a shell variable and never printed. It is passed on
# stdin, so it does not appear in the command line either.
show "OLD_PW=\$(kubectl get secret db-credentials-restore -n $NS -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
OLD_PW=$("$K" get secret db-credentials-restore -n "$NS" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
NEW=$("$PY" -c 'import secrets; print(secrets.token_urlsafe(24))')
printf '{"stringData":{"POSTGRES_PASSWORD":"%s"}}' "$NEW" > "$DIR/patch.json"
show "kubectl patch secret db-credentials-restore -n $NS --type merge --patch-file <generated patch file>"
"$K" patch secret db-credentials-restore -n "$NS" --type merge --patch-file "$DIR/patch.json" 2>&1
deadline=$((SECONDS + 300))
until [ "$("$K" exec -n "$NS" postgres-restore -- cat /run/secrets/db/password 2>/dev/null)" = "$NEW" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then break; fi
  sleep 10
done
if [ "$("$K" exec -n "$NS" postgres-restore -- cat /run/secrets/db/password 2>/dev/null)" = "$NEW" ]; then
  echo "secret volume carries the new value"
else
  echo "secret volume did not update within 300 seconds"
fi
inner='PGPASSWORD="$(cat /run/secrets/db/password)" psql -h <pod-ip> -U bookstore -d bookstore -tAc "select 1"'
show "kubectl exec -n $NS postgres-restore -- sh -c '$inner'"
"$K" exec -n "$NS" postgres-restore -- sh -c "${inner//<pod-ip>/$POD_IP}" 2>&1 | redact
inner='PGPASSWORD="$(cat)" psql -h <pod-ip> -U bookstore -d bookstore -tAc "select 1"'
show "printf '%s' \"\$OLD_PW\" | kubectl exec -i -n $NS postgres-restore -- sh -c '$inner'"
printf '%s' "$OLD_PW" | "$K" exec -i -n "$NS" postgres-restore -- sh -c "${inner//<pod-ip>/$POD_IP}" 2>&1 | redact
show "kubectl exec -i -n $NS postgres-restore -- sh -c 'psql -h /var/run/postgresql -U bookstore -d bookstore -v ON_ERROR_STOP=1' <<SQL"
cat <<'SQLTEXT'
\set pw `cat /run/secrets/db/password`
ALTER ROLE bookstore PASSWORD :'pw';
SQLTEXT
"$K" exec -i -n "$NS" postgres-restore -- sh -c 'psql -h /var/run/postgresql -U bookstore -d bookstore -v ON_ERROR_STOP=1' 2>&1 <<'SQL'
\set pw `cat /run/secrets/db/password`
ALTER ROLE bookstore PASSWORD :'pw';
SQL
inner='PGPASSWORD="$(cat /run/secrets/db/password)" psql -h <pod-ip> -U bookstore -d bookstore -tAc "select 1"'
show "kubectl exec -n $NS postgres-restore -- sh -c '$inner'"
"$K" exec -n "$NS" postgres-restore -- sh -c "${inner//<pod-ip>/$POD_IP}" 2>&1 | redact
inner='PGPASSWORD="$(cat)" psql -h <pod-ip> -U bookstore -d bookstore -tAc "select 1"'
show "printf '%s' \"\$OLD_PW\" | kubectl exec -i -n $NS postgres-restore -- sh -c '$inner'"
printf '%s' "$OLD_PW" | "$K" exec -i -n "$NS" postgres-restore -- sh -c "${inner//<pod-ip>/$POD_IP}" 2>&1 | redact
echo

echo "## step 10: clean up"
show "kubectl delete namespace $NS --wait=true --timeout=900s"
"$K" delete namespace "$NS" --wait=true --timeout=900s 2>&1
show "kubectl get pv -o jsonpath='{range .items[*]}{.spec.claimRef.namespace}{\"\\n\"}{end}' | grep -c '^$NS\$'"
"$K" get pv -o jsonpath='{range .items[*]}{.spec.claimRef.namespace}{"\n"}{end}' 2>/dev/null | grep -c "^$NS\$"
show "kubectl get namespace $NS"
"$K" get namespace "$NS" 2>&1
