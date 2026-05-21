package v1beta1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// BookstoreTenantSpec defines the desired state of a BookstoreTenant.
//
// A BookstoreTenant is a small, deliberately-bounded "give a tenant their own
// isolated slice of the Bookstore" custom resource. The controller reconciles
// it into a restricted-PodSecurity-compliant Namespace containing a Deployment
// + Service + ConfigMap. It is a TEACHING operator: the reconciled workload is
// a public pause image, not a real Bookstore service — the point is the
// controller machinery (watch -> reconcile -> status), not the payload. See
// Part 11 ch.02 and the explicit contrast with Part 08 ch.05 (consuming an
// operator) vs this (building one).
//
// v1beta1 is the HUB version: the schema below is the canonical one; v1alpha1
// is a thin spoke that converts to/from it (api/v1alpha1/*_conversion.go).
type BookstoreTenantSpec struct {
	// TenantName is the logical tenant identifier. The controller creates a
	// namespace named "bookstore-tenant-<tenantName>" and labels it for the
	// PodSecurity `restricted` standard.
	//
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=40
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	TenantName string `json:"tenantName"`

	// Replicas is the desired replica count for the tenant's placeholder
	// Deployment. Bounded on purpose: a tenant CR must not be able to ask for
	// an unbounded workload.
	//
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=5
	// +kubebuilder:default=1
	// +optional
	Replicas int32 `json:"replicas,omitempty"`

	// Tier selects a coarse resource profile applied to the tenant workload.
	// It exists so the conversion story (v1alpha1) has a field whose default
	// differs across versions — see the conversion code.
	//
	// +kubebuilder:validation:Enum=small;medium;large
	// +kubebuilder:default=small
	// +optional
	Tier string `json:"tier,omitempty"`
}

// BookstoreTenantStatus defines the observed state of a BookstoreTenant.
type BookstoreTenantStatus struct {
	// ObservedGeneration is the .metadata.generation the controller last
	// reconciled. status is stale unless ObservedGeneration == generation.
	//
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// Namespace is the tenant namespace the controller created/owns.
	//
	// +optional
	Namespace string `json:"namespace,omitempty"`

	// Phase is a single-word coarse summary (Pending|Provisioning|Ready|
	// Terminating) for `kubectl get`.
	//
	// +optional
	Phase string `json:"phase,omitempty"`

	// Conditions is the standard condition list. The controller sets a "Ready"
	// condition (and "Degraded" on error) using meta.SetStatusCondition.
	//
	// +optional
	// +patchMergeKey=type
	// +patchStrategy=merge
	// +listType=map
	// +listMapKey=type
	Conditions []metav1.Condition `json:"conditions,omitempty" patchStrategy:"merge" patchMergeKey:"type"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,shortName=btn
// +kubebuilder:storageversion
// +kubebuilder:printcolumn:name="Tenant",type=string,JSONPath=`.spec.tenantName`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Namespace",type=string,JSONPath=`.status.namespace`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// BookstoreTenant is the Schema for the bookstoretenants API.
// It is the HUB (and storage) version.
type BookstoreTenant struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   BookstoreTenantSpec   `json:"spec,omitempty"`
	Status BookstoreTenantStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// BookstoreTenantList contains a list of BookstoreTenant.
type BookstoreTenantList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []BookstoreTenant `json:"items"`
}

func init() {
	SchemeBuilder.Register(&BookstoreTenant{}, &BookstoreTenantList{})
}

// Hub marks v1beta1.BookstoreTenant as the conversion hub. controller-runtime's
// conversion machinery routes every spoke <-> spoke conversion THROUGH the hub,
// so only N spoke conversions are needed instead of N^2 pairwise ones.
func (*BookstoreTenant) Hub() {}
