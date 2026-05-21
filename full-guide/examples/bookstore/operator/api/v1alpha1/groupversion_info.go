// Package v1alpha1 contains API Schema definitions for the bookstore v1alpha1
// API group. v1alpha1 is a CONVERSION SPOKE: it is served for backward
// compatibility but is NOT the storage version. Every v1alpha1 object is
// converted to/from the v1beta1 HUB by the conversion webhook
// (bookstoretenant_conversion.go). Keeping a deprecated version served while
// the storage version moves forward is the standard API-evolution path
// (mirrors the built-in API lifecycle from Part 08 ch.01).
//
// +kubebuilder:object:generate=true
// +groupName=bookstore.example.com
package v1alpha1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion is group version used to register these objects.
	GroupVersion = schema.GroupVersion{Group: "bookstore.example.com", Version: "v1alpha1"}

	// SchemeBuilder is used to add go types to the GroupVersionKind scheme.
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme adds the types in this group-version to the given scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)
