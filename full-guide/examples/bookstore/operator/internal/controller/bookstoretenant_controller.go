// Package controller contains the BookstoreTenant reconciler.
//
// This is the level-triggered, idempotent reconcile loop Part 08 ch.05
// describes conceptually — here it is REAL Go (controller-runtime). The loop:
//
//	observe (Get the CR) -> if deleting, run finalizer cleanup ->
//	ensure finalizer present -> reconcile desired children
//	(Namespace, ConfigMap, Service, Deployment) via CreateOrUpdate with
//	owner references -> write .status (conditions + observedGeneration) ->
//	return (requeue on transient error).
//
// Every child is restricted-PodSecurity-compliant (runAsNonRoot, UID 65532,
// drop ALL, seccomp RuntimeDefault, read-only root FS) so it admits into the
// PodSecurity `restricted` tenant namespace the controller itself labels.
package controller

import (
	"context"
	"fmt"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	bookstorev1beta1 "github.com/bookstore/operator/api/v1beta1"
)

// tenantFinalizer is the finalizer key. While present on the CR, the apiserver
// will NOT actually delete the object — it sets .metadata.deletionTimestamp and
// blocks until every finalizer is removed. That is the window the controller
// uses to tear down anything that owner-reference GC would NOT clean up.
//
// What GC DOES clean up: the ConfigMap, Service, and Deployment carry an
// ownerReference to the CR (SetControllerReference), so the apiserver's garbage
// collector deletes them automatically when the CR is deleted.
//
// What GC does NOT clean up — and what the finalizer is FOR: the tenant
// **Namespace is cluster-scoped and CANNOT carry an ownerReference to a
// namespaced CR** (cross-scope owner refs are rejected by the apiserver — see
// reconcileNamespace). So nothing GC-collects the tenant namespace; a
// production finalizeTenant() must `r.Delete(ctx, ns)` it explicitly (plus any
// external state, e.g. de-provisioning a tenant in a billing system). **This
// minimal teaching demo deliberately does NOT delete the namespace** (its
// finalizeTenant only emits a terminal Event) — so the tenant namespace
// intentionally LEAKS here. That is precisely the finalizer footgun the
// chapter's Production notes warn about; a real operator deletes it.
const tenantFinalizer = "bookstore.example.com/tenant-finalizer"

// resourceProfiles maps the spec.tier to a (request,limit) CPU/memory pair.
type resourceProfile struct{ cpuReq, memReq, cpuLim, memLim string }

var resourceProfiles = map[string]resourceProfile{
	"small":  {"10m", "16Mi", "50m", "32Mi"},
	"medium": {"25m", "32Mi", "100m", "64Mi"},
	"large":  {"50m", "64Mi", "250m", "128Mi"},
}

// tenantImage is a tiny PUBLIC image (the same one Part 00 ch.04 uses for the
// reconcile demo) so the reconciled workload pulls anywhere with no kind load.
const tenantImage = "registry.k8s.io/pause:3.9"

// BookstoreTenantReconciler reconciles a BookstoreTenant object.
type BookstoreTenantReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Recorder record.EventRecorder
}

// RBAC markers — `make manifests` turns these into config/rbac/role.yaml. They
// are deliberately least-privilege: the operator manages exactly the child
// kinds it creates, plus its own CR + status + finalizers. Nothing cluster-wide
// beyond namespaces (it must create the tenant namespace).
//
// +kubebuilder:rbac:groups=bookstore.example.com,resources=bookstoretenants,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=bookstore.example.com,resources=bookstoretenants/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=bookstore.example.com,resources=bookstoretenants/finalizers,verbs=update
// +kubebuilder:rbac:groups=core,resources=namespaces,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=configmaps;services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=events,verbs=create;patch

// Reconcile is the level-triggered loop. It is idempotent: calling it on an
// already-correct tenant is a no-op (CreateOrUpdate diffs and only patches
// drift), and a missed/duplicate watch event is harmless because the loop
// always reconciles to the CURRENT desired state read from the cache.
func (r *BookstoreTenantReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// 1. OBSERVE — read desired state. NotFound => the CR is gone (and its
	//    owner-referenced children were GC'd); nothing to do.
	var tenant bookstorev1beta1.BookstoreTenant
	if err := r.Get(ctx, req.NamespacedName, &tenant); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// 2. DELETION — if marked for deletion, run finalizer cleanup then release.
	if !tenant.DeletionTimestamp.IsZero() {
		if controllerutil.ContainsFinalizer(&tenant, tenantFinalizer) {
			logger.Info("finalizing tenant", "tenant", tenant.Spec.TenantName)
			if err := r.finalizeTenant(ctx, &tenant); err != nil {
				return ctrl.Result{}, fmt.Errorf("finalize: %w", err)
			}
			controllerutil.RemoveFinalizer(&tenant, tenantFinalizer)
			if err := r.Update(ctx, &tenant); err != nil {
				return ctrl.Result{}, fmt.Errorf("remove finalizer: %w", err)
			}
		}
		return ctrl.Result{}, nil
	}

	// 3. ENSURE FINALIZER — register interest BEFORE creating children so a
	//    delete that races creation still triggers cleanup.
	if !controllerutil.ContainsFinalizer(&tenant, tenantFinalizer) {
		controllerutil.AddFinalizer(&tenant, tenantFinalizer)
		if err := r.Update(ctx, &tenant); err != nil {
			return ctrl.Result{}, fmt.Errorf("add finalizer: %w", err)
		}
		// Update changed the object; requeue to reconcile the fresh version.
		return ctrl.Result{Requeue: true}, nil
	}

	// 4. ACT — drive the world toward desired. Each step is CreateOrUpdate so
	//    the loop is idempotent and self-healing (drift is repaired).
	nsName := "bookstore-tenant-" + tenant.Spec.TenantName
	if err := r.reconcileNamespace(ctx, &tenant, nsName); err != nil {
		return r.failed(ctx, &tenant, "NamespaceError", err)
	}
	if err := r.reconcileConfigMap(ctx, &tenant, nsName); err != nil {
		return r.failed(ctx, &tenant, "ConfigMapError", err)
	}
	if err := r.reconcileService(ctx, &tenant, nsName); err != nil {
		return r.failed(ctx, &tenant, "ServiceError", err)
	}
	if err := r.reconcileDeployment(ctx, &tenant, nsName); err != nil {
		return r.failed(ctx, &tenant, "DeploymentError", err)
	}

	// 5. STATUS — write observed state back. observedGeneration lets clients
	//    tell "the controller has processed THIS spec" from a stale status.
	tenant.Status.ObservedGeneration = tenant.Generation
	tenant.Status.Namespace = nsName
	tenant.Status.Phase = "Ready"
	meta.SetStatusCondition(&tenant.Status.Conditions, metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionTrue,
		ObservedGeneration: tenant.Generation,
		Reason:             "Reconciled",
		Message:            "Tenant namespace and workload are provisioned",
	})
	if err := r.Status().Update(ctx, &tenant); err != nil {
		return ctrl.Result{}, fmt.Errorf("update status: %w", err)
	}
	r.Recorder.Event(&tenant, corev1.EventTypeNormal, "Reconciled",
		fmt.Sprintf("tenant %q reconciled into namespace %q", tenant.Spec.TenantName, nsName))
	return ctrl.Result{}, nil
}

// failed records a Degraded condition + Warning Event and returns the error so
// controller-runtime requeues with exponential backoff (transient errors
// self-heal; a real bug surfaces on the CR's status and events).
func (r *BookstoreTenantReconciler) failed(ctx context.Context, t *bookstorev1beta1.BookstoreTenant, reason string, cause error) (ctrl.Result, error) {
	t.Status.Phase = "Degraded"
	meta.SetStatusCondition(&t.Status.Conditions, metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionFalse,
		ObservedGeneration: t.Generation,
		Reason:             reason,
		Message:            cause.Error(),
	})
	// Best-effort status write; the returned error drives the requeue.
	_ = r.Status().Update(ctx, t)
	r.Recorder.Event(t, corev1.EventTypeWarning, reason, cause.Error())
	return ctrl.Result{}, cause
}

// finalizeTenant is the pre-delete hook. Owner-reference GC already removes the
// owner-referenced child objects (ConfigMap/Service/Deployment); this is where
// teardown that GC CANNOT express goes:
//
//   - The tenant **Namespace** — cluster-scoped, so it carries NO ownerRef to
//     the namespaced CR (see reconcileNamespace) and GC never deletes it. A
//     production finalizer MUST delete it explicitly, e.g.:
//
//     ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "bookstore-tenant-" + t.Spec.TenantName}}
//     if err := r.Delete(ctx, ns); err != nil && !apierrors.IsNotFound(err) { return err }
//
//   - IRREVERSIBLE / EXTERNAL state (revoke a tenant API key, drop a billing
//     record) — anything outside the cluster GC knows nothing about.
//
// This MINIMAL teaching demo deliberately does NEITHER (it only emits a
// terminal Event so the pattern is observable) — so the tenant namespace
// intentionally LEAKS. That omission IS the finalizer footgun the chapter's
// Production notes call out; a real operator does the r.Delete above.
//
// It takes ctx and threads it into every API call (real cleanup — an external
// revoke, the r.Delete above — needs cancellation/deadline propagation). It
// MUST be idempotent — the finalizer can run more than once.
func (r *BookstoreTenantReconciler) finalizeTenant(ctx context.Context, t *bookstorev1beta1.BookstoreTenant) error {
	// (ctx is threaded here so real teardown — e.g. r.Delete(ctx, ns) or an
	// external API call honouring ctx — is cancellation-aware. The minimal
	// body below does no API work, but models the signature a real one needs.)
	_ = ctx
	r.Recorder.Event(t, corev1.EventTypeNormal, "Finalized",
		fmt.Sprintf("external state for tenant %q released "+
			"(note: this demo does NOT delete namespace bookstore-tenant-%s — it leaks; a real operator r.Delete()s it here)",
			t.Spec.TenantName, t.Spec.TenantName))
	return nil
}

func (r *BookstoreTenantReconciler) reconcileNamespace(ctx context.Context, t *bookstorev1beta1.BookstoreTenant, nsName string) error {
	ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: nsName}}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, ns, func() error {
		if ns.Labels == nil {
			ns.Labels = map[string]string{}
		}
		// Label the tenant namespace for the PodSecurity `restricted`
		// standard — the SAME enforcement as the canonical `bookstore` ns
		// (Part 05 ch.02). The tenant workload below is built to satisfy it.
		ns.Labels["pod-security.kubernetes.io/enforce"] = "restricted"
		ns.Labels["pod-security.kubernetes.io/enforce-version"] = "latest"
		ns.Labels["pod-security.kubernetes.io/warn"] = "restricted"
		ns.Labels["pod-security.kubernetes.io/audit"] = "restricted"
		ns.Labels["app.kubernetes.io/managed-by"] = "bookstore-operator"
		ns.Labels["bookstore.example.com/tenant"] = t.Spec.TenantName
		// A Namespace is cluster-scoped: it CANNOT carry an owner reference to
		// a namespaced CR (cross-scope owner refs are rejected by the
		// apiserver). So GC does NOT delete this namespace when the CR is
		// deleted — only the owner-referenced objects INSIDE it (ConfigMap/
		// Service/Deployment) are GC'd. A production finalizeTenant() must
		// `r.Delete` this namespace explicitly; this minimal demo deliberately
		// does NOT (the tenant ns intentionally leaks — see finalizeTenant and
		// the chapter's Production notes).
		return nil
	})
	return err
}

func (r *BookstoreTenantReconciler) reconcileConfigMap(ctx context.Context, t *bookstorev1beta1.BookstoreTenant, nsName string) error {
	cm := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: "tenant-config", Namespace: nsName}}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, cm, func() error {
		cm.Data = map[string]string{
			"TENANT_NAME": t.Spec.TenantName,
			"TIER":        t.Spec.Tier,
		}
		return controllerutil.SetControllerReference(t, cm, r.Scheme)
	})
	return err
}

func (r *BookstoreTenantReconciler) reconcileService(ctx context.Context, t *bookstorev1beta1.BookstoreTenant, nsName string) error {
	svc := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: "tenant", Namespace: nsName}}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, svc, func() error {
		svc.Spec.Selector = map[string]string{"app": "tenant", "tenant": t.Spec.TenantName}
		svc.Spec.Ports = []corev1.ServicePort{{Name: "http", Port: 80, TargetPort: intstr.FromInt32(8080)}}
		return controllerutil.SetControllerReference(t, svc, r.Scheme)
	})
	return err
}

func (r *BookstoreTenantReconciler) reconcileDeployment(ctx context.Context, t *bookstorev1beta1.BookstoreTenant, nsName string) error {
	prof, ok := resourceProfiles[t.Spec.Tier]
	if !ok {
		prof = resourceProfiles["small"]
	}
	replicas := t.Spec.Replicas
	labels := map[string]string{"app": "tenant", "tenant": t.Spec.TenantName}

	dep := &appsv1.Deployment{ObjectMeta: metav1.ObjectMeta{Name: "tenant", Namespace: nsName}}
	_, err := controllerutil.CreateOrUpdate(ctx, r.Client, dep, func() error {
		dep.Spec.Replicas = &replicas
		dep.Spec.Selector = &metav1.LabelSelector{MatchLabels: labels}
		dep.Spec.Template.ObjectMeta.Labels = labels
		dep.Spec.Template.Spec = corev1.PodSpec{
			// restricted-PodSecurity pod-level securityContext.
			SecurityContext: &corev1.PodSecurityContext{
				RunAsNonRoot:   ptrBool(true),
				RunAsUser:      ptrInt64(65532),
				SeccompProfile: &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeRuntimeDefault},
			},
			// NOTE: no liveness/readiness probes here ON PURPOSE —
			// registry.k8s.io/pause:3.9 runs no HTTP/TCP server, so any probe
			// would fail. A REAL operator reconciling a real workload MUST set
			// probes appropriate to that image (httpGet/tcpSocket/exec) — do
			// not copy this probe-less Deployment for an actual service
			// (Part 01 ch.02). The pause image is only a stand-in so the
			// controller MACHINERY is the lesson, not the payload.
			Containers: []corev1.Container{{
				Name:  "pause",
				Image: tenantImage,
				Resources: corev1.ResourceRequirements{
					Requests: corev1.ResourceList{
						corev1.ResourceCPU:    resource.MustParse(prof.cpuReq),
						corev1.ResourceMemory: resource.MustParse(prof.memReq),
					},
					Limits: corev1.ResourceList{
						corev1.ResourceCPU:    resource.MustParse(prof.cpuLim),
						corev1.ResourceMemory: resource.MustParse(prof.memLim),
					},
				},
				// restricted-PodSecurity container-level securityContext.
				SecurityContext: &corev1.SecurityContext{
					AllowPrivilegeEscalation: ptrBool(false),
					RunAsNonRoot:             ptrBool(true),
					ReadOnlyRootFilesystem:   ptrBool(true),
					Capabilities:             &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}},
					SeccompProfile:           &corev1.SeccompProfile{Type: corev1.SeccompProfileTypeRuntimeDefault},
				},
			}},
		}
		return controllerutil.SetControllerReference(t, dep, r.Scheme)
	})
	return err
}

// SetupWithManager wires the controller: watch BookstoreTenant, and Owns() the
// child kinds so a change to (or deletion of) a controller-created object
// re-enqueues its owner — the standard owner-ref + watch pattern.
func (r *BookstoreTenantReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&bookstorev1beta1.BookstoreTenant{}).
		Owns(&appsv1.Deployment{}).
		Owns(&corev1.Service{}).
		Owns(&corev1.ConfigMap{}).
		Named("bookstoretenant").
		Complete(r)
}

// --- tiny helpers (kept local; controller-runtime ships ptr.To, but explicit
// helpers keep the chapter's code snippets self-contained) ------------------

func ptrBool(b bool) *bool    { return &b }
func ptrInt64(i int64) *int64 { return &i }

// compile-time assertion: the reconciler satisfies the Reconciler interface.
var _ reconcile.Reconciler = &BookstoreTenantReconciler{}
