package controller

import (
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	bookstorev1beta1 "github.com/bookstore/operator/api/v1beta1"
)

// envtest-backed behavioural tests for the reconcile loop. They assert the
// load-bearing properties: a CR produces an owner-referenced, restricted child
// Deployment; the loop is idempotent; status carries observedGeneration + a
// Ready condition. (Skipped automatically when envtest binaries are absent —
// see suite_test.go.)
var _ = Describe("BookstoreTenant controller", func() {
	const tenantName = "acme"
	crKey := types.NamespacedName{Name: "tenant-sample", Namespace: "default"}

	reconcileOnce := func(r *BookstoreTenantReconciler) {
		_, err := r.Reconcile(ctx, reconcile.Request{NamespacedName: crKey})
		Expect(err).NotTo(HaveOccurred())
	}

	It("provisions a restricted, owner-referenced workload and writes status", func() {
		if k8sClient == nil {
			Skip("envtest unavailable")
		}
		recorder := newFakeRecorder()
		r := &BookstoreTenantReconciler{Client: k8sClient, Scheme: k8sClient.Scheme(), Recorder: recorder}

		cr := &bookstorev1beta1.BookstoreTenant{
			ObjectMeta: metav1.ObjectMeta{Name: crKey.Name, Namespace: crKey.Namespace},
			Spec:       bookstorev1beta1.BookstoreTenantSpec{TenantName: tenantName, Replicas: 2, Tier: "medium"},
		}
		Expect(k8sClient.Create(ctx, cr)).To(Succeed())

		// First pass adds the finalizer and requeues; subsequent passes
		// converge children + status (level-triggered: just run the loop).
		Eventually(func() error {
			reconcileOnce(r)
			var got bookstorev1beta1.BookstoreTenant
			if err := k8sClient.Get(ctx, crKey, &got); err != nil {
				return err
			}
			if got.Status.Phase != "Ready" {
				return apierrors.NewBadRequest("not ready yet")
			}
			return nil
		}, 10*time.Second, 250*time.Millisecond).Should(Succeed())

		nsName := "bookstore-tenant-" + tenantName

		By("creating a restricted-compliant Deployment owned by the CR")
		var dep appsv1.Deployment
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "tenant", Namespace: nsName}, &dep)).To(Succeed())
		Expect(*dep.Spec.Replicas).To(Equal(int32(2)))
		Expect(*dep.Spec.Template.Spec.SecurityContext.RunAsNonRoot).To(BeTrue())
		c := dep.Spec.Template.Spec.Containers[0]
		Expect(*c.SecurityContext.AllowPrivilegeEscalation).To(BeFalse())
		Expect(c.SecurityContext.Capabilities.Drop).To(ContainElement(corev1.Capability("ALL")))
		Expect(dep.OwnerReferences).NotTo(BeEmpty())
		Expect(dep.OwnerReferences[0].Kind).To(Equal("BookstoreTenant"))

		By("recording observedGeneration and a Ready condition")
		var got bookstorev1beta1.BookstoreTenant
		Expect(k8sClient.Get(ctx, crKey, &got)).To(Succeed())
		Expect(got.Status.ObservedGeneration).To(Equal(got.Generation))
		Expect(got.Status.Namespace).To(Equal(nsName))
		cond := findCondition(got.Status.Conditions, "Ready")
		Expect(cond).NotTo(BeNil())
		Expect(cond.Status).To(Equal(metav1.ConditionTrue))

		By("being idempotent: a second reconcile changes nothing")
		var depBefore appsv1.Deployment
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "tenant", Namespace: nsName}, &depBefore)).To(Succeed())
		reconcileOnce(r)
		var depAfter appsv1.Deployment
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "tenant", Namespace: nsName}, &depAfter)).To(Succeed())
		Expect(depAfter.Generation).To(Equal(depBefore.Generation))
	})
})

func findCondition(conds []metav1.Condition, t string) *metav1.Condition {
	for i := range conds {
		if conds[i].Type == t {
			return &conds[i]
		}
	}
	return nil
}
