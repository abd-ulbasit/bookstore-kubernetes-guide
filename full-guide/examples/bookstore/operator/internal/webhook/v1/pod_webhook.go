// Package webhookv1 implements the Bookstore admission webhooks. These are the
// LOWER-LEVEL primitive that Kyverno/Gatekeeper (Part 05 ch.03) are built on
// top of: an HTTPS server the apiserver calls during the admission pipeline
// (Part 00 ch.04). Two webhooks on core/v1 Pods:
//
//   - MUTATING (CustomDefaulter): stamps the recommended
//     app.kubernetes.io/managed-by label and fills in a default restricted
//     securityContext when one is absent. Runs BEFORE schema + validation, so
//     a later validating webhook (or PodSecurity) sees the mutated object.
//   - VALIDATING (CustomValidator): in the `bookstore` namespace, REJECTS Pods
//     that are not restricted-PodSecurity-compliant — reinforcing PSA at the
//     app layer (defense in depth; PSA is the floor, this adds a project rule).
//
// controller-runtime turns CustomDefaulter/CustomValidator into the
// /mutate-... and /validate-... HTTP handlers and serves them on the manager's
// webhook server (TLS). The MutatingWebhookConfiguration /
// ValidatingWebhookConfiguration objects (config/webhook) point the apiserver
// at those paths and carry the caBundle (cert-manager injects it).
package webhookv1

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/webhook"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

var podlog = logf.Log.WithName("pod-webhook")

// SetupPodWebhookWithManager registers BOTH webhooks for core/v1 Pod on the
// manager's (shared, TLS) webhook server.
func SetupPodWebhookWithManager(mgr ctrl.Manager) error {
	return ctrl.NewWebhookManagedBy(mgr).
		For(&corev1.Pod{}).
		WithDefaulter(&PodDefaulter{}).
		WithValidator(&PodValidator{}).
		Complete()
}

// +kubebuilder:webhook:path=/mutate--v1-pod,mutating=true,failurePolicy=ignore,sideEffects=None,groups="",resources=pods,verbs=create;update,versions=v1,name=mpod.bookstore.example.com,admissionReviewVersions=v1
// +kubebuilder:webhook:path=/validate--v1-pod,mutating=false,failurePolicy=fail,sideEffects=None,groups="",resources=pods,verbs=create;update,versions=v1,name=vpod.bookstore.example.com,admissionReviewVersions=v1

// --- MUTATING ---------------------------------------------------------------

// PodDefaulter implements admission.CustomDefaulter — the mutating webhook.
type PodDefaulter struct{}

var _ webhook.CustomDefaulter = &PodDefaulter{}

const managedByLabel = "app.kubernetes.io/managed-by"

// Default mutates an incoming Pod. It MUST be idempotent: admission can call it
// more than once (e.g. reinvocationPolicy), and re-running it must not keep
// changing the object.
func (d *PodDefaulter) Default(_ context.Context, obj runtime.Object) error {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		return fmt.Errorf("expected a Pod but got a %T", obj)
	}
	podlog.V(1).Info("mutating pod", "name", pod.GetName(), "ns", pod.GetNamespace())

	// 1. Stamp the recommended label if missing (idempotent: set-if-absent).
	if pod.Labels == nil {
		pod.Labels = map[string]string{}
	}
	if _, has := pod.Labels[managedByLabel]; !has {
		pod.Labels[managedByLabel] = "bookstore-webhook"
	}

	// 2. Supply a default restricted pod-level securityContext if none is set.
	//    This is a CONVENIENCE default, not the enforcement — the validating
	//    webhook (and PSA) still reject a Pod that overrides it unsafely.
	if pod.Spec.SecurityContext == nil {
		pod.Spec.SecurityContext = &corev1.PodSecurityContext{}
	}
	if pod.Spec.SecurityContext.RunAsNonRoot == nil {
		pod.Spec.SecurityContext.RunAsNonRoot = ptrBool(true)
	}
	if pod.Spec.SecurityContext.SeccompProfile == nil {
		pod.Spec.SecurityContext.SeccompProfile = &corev1.SeccompProfile{
			Type: corev1.SeccompProfileTypeRuntimeDefault,
		}
	}
	return nil
}

// --- VALIDATING -------------------------------------------------------------

// PodValidator implements admission.CustomValidator — the validating webhook.
// It does NOT mutate (validation must be side-effect-free w.r.t. the object).
type PodValidator struct{}

var _ webhook.CustomValidator = &PodValidator{}

// guardedNamespace is the namespace this project rule applies to. The webhook
// configuration ALSO scopes by namespaceSelector so kube-system and the
// operator's own namespace are excluded at the apiserver (the deadlock-
// avoidance footgun taught in the chapter); this in-code check is the
// app-layer rule itself.
const guardedNamespace = "bookstore"

func (v *PodValidator) ValidateCreate(_ context.Context, obj runtime.Object) (admission.Warnings, error) {
	return v.validate(obj)
}

func (v *PodValidator) ValidateUpdate(_ context.Context, _ runtime.Object, newObj runtime.Object) (admission.Warnings, error) {
	return v.validate(newObj)
}

func (v *PodValidator) ValidateDelete(_ context.Context, _ runtime.Object) (admission.Warnings, error) {
	// Nothing to validate on delete.
	return nil, nil
}

// validate enforces the restricted-compliance project rule for Pods in the
// guarded namespace. Returning a non-nil error makes the apiserver REJECT the
// request with that message.
func (v *PodValidator) validate(obj runtime.Object) (admission.Warnings, error) {
	pod, ok := obj.(*corev1.Pod)
	if !ok {
		return nil, fmt.Errorf("expected a Pod but got a %T", obj)
	}
	if pod.Namespace != guardedNamespace {
		return nil, nil // out of scope; allow
	}

	var violations []string

	sc := pod.Spec.SecurityContext
	if sc == nil || sc.RunAsNonRoot == nil || !*sc.RunAsNonRoot {
		violations = append(violations, "spec.securityContext.runAsNonRoot must be true")
	}

	for i := range pod.Spec.Containers {
		c := &pod.Spec.Containers[i]
		csc := c.SecurityContext
		if csc == nil {
			violations = append(violations, fmt.Sprintf("container %q: securityContext is required", c.Name))
			continue
		}
		if csc.AllowPrivilegeEscalation == nil || *csc.AllowPrivilegeEscalation {
			violations = append(violations, fmt.Sprintf("container %q: allowPrivilegeEscalation must be false", c.Name))
		}
		if csc.Capabilities == nil || !dropsALL(csc.Capabilities) {
			violations = append(violations, fmt.Sprintf("container %q: capabilities must drop [\"ALL\"]", c.Name))
		}
	}

	if len(violations) > 0 {
		return nil, fmt.Errorf("pod %q is not restricted-PodSecurity-compliant: %v", pod.Name, violations)
	}
	return nil, nil
}

func dropsALL(caps *corev1.Capabilities) bool {
	for _, d := range caps.Drop {
		if d == "ALL" {
			return true
		}
	}
	return false
}

func ptrBool(b bool) *bool { return &b }
