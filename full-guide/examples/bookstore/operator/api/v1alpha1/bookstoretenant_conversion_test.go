package v1alpha1

import (
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	v1beta1 "github.com/bookstore/operator/api/v1beta1"
)

// Plain (non-Ginkgo) table-driven tests for the hub/spoke conversion. These
// need NO cluster and NO envtest, so `go test ./...` is GREEN on a
// toolchain-only machine (the envtest-backed controller suite is correctly
// SKIPPED there — see internal/controller/suite_test.go). They also pin the
// load-bearing contract: ConvertTo/ConvertFrom round-trip and the size<->tier
// remap is correct, including the unknown-value fallback.

func TestConvertTo_SizeToTier(t *testing.T) {
	tests := []struct {
		name     string
		size     string
		wantTier string
	}{
		{"small", "s", "small"},
		{"medium", "m", "medium"},
		{"large", "l", "large"},
		{"unknown falls back to small", "xl", "small"},
		{"empty falls back to small", "", "small"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			src := &BookstoreTenant{
				ObjectMeta: metav1.ObjectMeta{Name: "acme", Namespace: "default"},
				Spec:       BookstoreTenantSpec{TenantName: "acme", Replicas: 2, Size: tc.size},
			}
			var dst v1beta1.BookstoreTenant
			if err := src.ConvertTo(&dst); err != nil {
				t.Fatalf("ConvertTo: unexpected error: %v", err)
			}
			if dst.Spec.Tier != tc.wantTier {
				t.Errorf("Tier = %q, want %q", dst.Spec.Tier, tc.wantTier)
			}
			if dst.Spec.TenantName != "acme" || dst.Spec.Replicas != 2 {
				t.Errorf("identical fields not copied: %+v", dst.Spec)
			}
			if dst.Name != "acme" || dst.Namespace != "default" {
				t.Errorf("ObjectMeta not copied: %s/%s", dst.Namespace, dst.Name)
			}
		})
	}
}

func TestConvertFrom_TierToSize(t *testing.T) {
	tests := []struct {
		name     string
		tier     string
		wantSize string
	}{
		{"small", "small", "s"},
		{"medium", "medium", "m"},
		{"large", "large", "l"},
		{"unknown falls back to s", "huge", "s"},
		{"empty falls back to s", "", "s"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			src := &v1beta1.BookstoreTenant{
				ObjectMeta: metav1.ObjectMeta{Name: "acme", Namespace: "default"},
				Spec:       v1beta1.BookstoreTenantSpec{TenantName: "acme", Replicas: 3, Tier: tc.tier},
			}
			var dst BookstoreTenant
			if err := dst.ConvertFrom(src); err != nil {
				t.Fatalf("ConvertFrom: unexpected error: %v", err)
			}
			if dst.Spec.Size != tc.wantSize {
				t.Errorf("Size = %q, want %q", dst.Spec.Size, tc.wantSize)
			}
			if dst.Spec.TenantName != "acme" || dst.Spec.Replicas != 3 {
				t.Errorf("identical fields not copied: %+v", dst.Spec)
			}
		})
	}
}

// TestRoundTrip asserts spoke -> hub -> spoke preserves the known enum values
// (the property a conversion webhook MUST hold so served versions stay stable).
func TestRoundTrip(t *testing.T) {
	for _, size := range []string{"s", "m", "l"} {
		src := &BookstoreTenant{
			ObjectMeta: metav1.ObjectMeta{Name: "rt", Namespace: "ns"},
			Spec:       BookstoreTenantSpec{TenantName: "rt", Replicas: 1, Size: size},
		}
		var hub v1beta1.BookstoreTenant
		if err := src.ConvertTo(&hub); err != nil {
			t.Fatalf("ConvertTo(%q): %v", size, err)
		}
		var back BookstoreTenant
		if err := back.ConvertFrom(&hub); err != nil {
			t.Fatalf("ConvertFrom(%q): %v", size, err)
		}
		if back.Spec.Size != size {
			t.Errorf("round-trip size: got %q, want %q (via tier %q)", back.Spec.Size, size, hub.Spec.Tier)
		}
	}
}
