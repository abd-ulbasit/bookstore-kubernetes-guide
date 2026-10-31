// Command manager is the BookstoreTenant operator + admission-webhook binary.
//
// One controller-runtime Manager hosts: the BookstoreTenant controller (the
// reconcile loop), the conversion webhook (v1alpha1 <-> v1beta1 hub: both
// versions on the scheme, and a webhook builder for the hub that serves
// /convert), and the Pod admission webhooks (mutating + validating). It serves
// /healthz, /readyz and the webhook TLS
// server, and uses leader election so a multi-replica Deployment runs exactly
// one active reconciler (HA without doing work twice — Part 00 ch.04).
//
// Built into a distroless, restricted-compliant image (see Dockerfile) — the
// SAME build pattern as the Bookstore catalog service.
package main

import (
	"crypto/tls"
	"flag"
	"os"

	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/webhook"

	bookstorev1alpha1 "github.com/bookstore/operator/api/v1alpha1"
	bookstorev1beta1 "github.com/bookstore/operator/api/v1beta1"
	"github.com/bookstore/operator/internal/controller"
	webhookv1 "github.com/bookstore/operator/internal/webhook/v1"
)

var (
	scheme   = runtime.NewScheme()
	setupLog = ctrl.Log.WithName("setup")
)

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	// Registering BOTH versions on the scheme lets controller-runtime convert
	// between them: the hub (v1beta1) plus the spoke's ConvertTo/ConvertFrom.
	// The scheme alone does not serve /convert; the webhook builder below does.
	utilruntime.Must(bookstorev1alpha1.AddToScheme(scheme))
	utilruntime.Must(bookstorev1beta1.AddToScheme(scheme))
}

func main() {
	var metricsAddr string
	var probeAddr string
	var enableLeaderElection bool
	flag.StringVar(&metricsAddr, "metrics-bind-address", "0", "Metrics endpoint bind address ('0' disables it).")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "Health-probe endpoint bind address.")
	flag.BoolVar(&enableLeaderElection, "leader-elect", false,
		"Enable leader election so only one controller-manager replica is active.")
	opts := zap.Options{Development: true}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))

	// TLS 1.2 floor for the webhook server.
	tlsOpts := []func(*tls.Config){func(c *tls.Config) { c.MinVersion = tls.VersionTLS12 }}

	// controller-runtime v0.21+ hands back a rest.Config with client-side rate
	// limiting OFF (it leans on API Priority and Fairness alone). Restore the
	// earlier 20 QPS / 30 burst so the operator is polite on its own and the
	// APF objects in config/apf/ stay the backstop, not the only control.
	restCfg := ctrl.GetConfigOrDie()
	restCfg.QPS = 20
	restCfg.Burst = 30

	mgr, err := ctrl.NewManager(restCfg, ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		WebhookServer:          webhook.NewServer(webhook.Options{Port: 9443, TLSOpts: tlsOpts}),
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         enableLeaderElection,
		LeaderElectionID:       "bookstore-operator.bookstore.example.com",
	})
	if err != nil {
		setupLog.Error(err, "unable to start manager")
		os.Exit(1)
	}

	if err = (&controller.BookstoreTenantReconciler{
		Client:   mgr.GetClient(),
		Scheme:   mgr.GetScheme(),
		Recorder: mgr.GetEventRecorder("bookstoretenant-controller"),
	}).SetupWithManager(mgr); err != nil {
		setupLog.Error(err, "unable to create controller", "controller", "BookstoreTenant")
		os.Exit(1)
	}

	// Conversion webhook. controller-runtime serves /convert only when a
	// webhook builder registers the hub type; the scheme registration above is
	// not enough, and the apiserver's CRD conversion call would get a 404. This
	// is deliberately outside the ENABLE_WEBHOOKS check: the CRD's conversion
	// strategy needs /convert whether or not the Pod admission webhooks run.
	if err = ctrl.NewWebhookManagedBy(mgr, &bookstorev1beta1.BookstoreTenant{}).Complete(); err != nil {
		setupLog.Error(err, "unable to register conversion webhook", "type", "BookstoreTenant")
		os.Exit(1)
	}

	// Pod admission webhooks (mutating + validating). Skippable for local
	// `go run` without certs via ENABLE_WEBHOOKS=false (the Kubebuilder
	// convention) so the controller can be exercised on its own.
	if os.Getenv("ENABLE_WEBHOOKS") != "false" {
		if err = webhookv1.SetupPodWebhookWithManager(mgr); err != nil {
			setupLog.Error(err, "unable to create webhook", "webhook", "Pod")
			os.Exit(1)
		}
	}

	if err = mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err = mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		setupLog.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	setupLog.Info("starting manager")
	if err = mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		setupLog.Error(err, "problem running manager")
		os.Exit(1)
	}
}
