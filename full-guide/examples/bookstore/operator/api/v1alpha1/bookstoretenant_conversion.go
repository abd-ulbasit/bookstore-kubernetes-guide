package v1alpha1

import (
	"sigs.k8s.io/controller-runtime/pkg/conversion"

	v1beta1 "github.com/bookstore/operator/api/v1beta1"
)

// This file implements the SPOKE side of the conversion webhook. v1beta1 is the
// HUB (it implements Hub()); v1alpha1 implements Convertible (ConvertTo /
// ConvertFrom). The apiserver calls the operator's /convert endpoint whenever a
// client reads/writes a version other than the storage version, and the
// machinery routes everything THROUGH the hub:
//
//	read v1alpha1, stored v1beta1:   hub(v1beta1) --ConvertFrom--> v1alpha1
//	write v1alpha1, store v1beta1:   v1alpha1 --ConvertTo--> hub(v1beta1)
//
// Only the spoke<->hub mapping is implemented here; with N versions you write
// N-1 spoke conversions, not N^2 pairwise ones — that is the whole point of the
// hub-and-spoke model.

// sizeToTier maps the v1alpha1 `size` enum to the v1beta1 `tier` enum.
var sizeToTier = map[string]string{"s": "small", "m": "medium", "l": "large"}

// tierToSize is the inverse of sizeToTier.
var tierToSize = map[string]string{"small": "s", "medium": "m", "large": "l"}

// ConvertTo converts this v1alpha1 BookstoreTenant (spoke) to the v1beta1 Hub.
func (src *BookstoreTenant) ConvertTo(dstRaw conversion.Hub) error {
	dst := dstRaw.(*v1beta1.BookstoreTenant)

	// ObjectMeta is version-independent — copy verbatim.
	dst.ObjectMeta = src.ObjectMeta

	// Spec: tenantName/replicas are identical; size -> tier is the real work.
	dst.Spec.TenantName = src.Spec.TenantName
	dst.Spec.Replicas = src.Spec.Replicas
	if tier, ok := sizeToTier[src.Spec.Size]; ok {
		dst.Spec.Tier = tier
	} else {
		// Unknown/empty size: fall back to the safe default rather than
		// produce an out-of-enum hub object.
		dst.Spec.Tier = "small"
	}

	// Status is identical across versions — straight copy.
	dst.Status.ObservedGeneration = src.Status.ObservedGeneration
	dst.Status.Namespace = src.Status.Namespace
	dst.Status.Phase = src.Status.Phase
	dst.Status.Conditions = src.Status.Conditions

	return nil
}

// ConvertFrom converts the v1beta1 Hub into this v1alpha1 BookstoreTenant.
func (dst *BookstoreTenant) ConvertFrom(srcRaw conversion.Hub) error {
	src := srcRaw.(*v1beta1.BookstoreTenant)

	dst.ObjectMeta = src.ObjectMeta

	dst.Spec.TenantName = src.Spec.TenantName
	dst.Spec.Replicas = src.Spec.Replicas
	if size, ok := tierToSize[src.Spec.Tier]; ok {
		dst.Spec.Size = size
	} else {
		dst.Spec.Size = "s"
	}

	dst.Status.ObservedGeneration = src.Status.ObservedGeneration
	dst.Status.Namespace = src.Status.Namespace
	dst.Status.Phase = src.Status.Phase
	dst.Status.Conditions = src.Status.Conditions

	return nil
}
