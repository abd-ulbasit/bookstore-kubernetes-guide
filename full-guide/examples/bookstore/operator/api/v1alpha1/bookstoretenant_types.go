package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// BookstoreTenantSpec (v1alpha1) is the ORIGINAL, deprecated shape. It differs
// from the v1beta1 hub on purpose so the conversion has real work to do:
//
//	v1alpha1                    v1beta1 (hub)
//	--------                    -------------
//	tenantName            <-->  tenantName        (identical)
//	replicas              <-->  replicas          (identical)
//	size  ("s"/"m"/"l")   <-->  tier ("small"/    (RENAMED + REMAPPED VALUES)
//	                             "medium"/"large")
//
// The conversion code (bookstoretenant_conversion.go) maps `size` <-> `tier`.
// This is the canonical "we renamed/reshaped a field across an API version"
// scenario a conversion webhook exists for.
type BookstoreTenantSpec struct {
	// TenantName — see v1beta1; unchanged across versions.
	//
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=40
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	TenantName string `json:"tenantName"`

	// Replicas — see v1beta1; unchanged across versions.
	//
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=5
	// +kubebuilder:default=1
	// +optional
	Replicas int32 `json:"replicas,omitempty"`

	// Size is the v1alpha1 resource-profile selector. v1beta1 renamed this to
	// `tier` and changed the enum values ("s"->"small" etc). The conversion
	// webhook remaps it; an unknown/empty value defaults to the small profile.
	//
	// +kubebuilder:validation:Enum=s;m;l
	// +kubebuilder:default=s
	// +optional
	Size string `json:"size,omitempty"`
}

// BookstoreTenantStatus (v1alpha1) — identical fields to the hub; copied
// straight through by the conversion.
type BookstoreTenantStatus struct {
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
	// +optional
	Namespace string `json:"namespace,omitempty"`
	// +optional
	Phase string `json:"phase,omitempty"`
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
// +kubebuilder:printcolumn:name="Tenant",type=string,JSONPath=`.spec.tenantName`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// BookstoreTenant is the v1alpha1 (spoke) schema for the bookstoretenants API.
type BookstoreTenant struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   BookstoreTenantSpec   `json:"spec,omitempty"`
	Status BookstoreTenantStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// BookstoreTenantList contains a list of v1alpha1 BookstoreTenant.
type BookstoreTenantList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []BookstoreTenant `json:"items"`
}

func init() {
	SchemeBuilder.Register(&BookstoreTenant{}, &BookstoreTenantList{})
}
