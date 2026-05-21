// Package v1beta1 contains API Schema definitions for the bookstore v1beta1 API
// group. v1beta1 is the CONVERSION HUB and the etcd STORAGE version: every
// other version (v1alpha1) converts to/from this one, and this is the shape
// persisted in etcd. See api/v1alpha1/*_conversion.go for the spoke side.
//
// +kubebuilder:object:generate=true
// +groupName=bookstore.example.com
package v1beta1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion is group version used to register these objects.
	GroupVersion = schema.GroupVersion{Group: "bookstore.example.com", Version: "v1beta1"}

	// SchemeBuilder is used to add go types to the GroupVersionKind scheme.
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme adds the types in this group-version to the given scheme.
	AddToScheme = SchemeBuilder.AddToScheme
)
