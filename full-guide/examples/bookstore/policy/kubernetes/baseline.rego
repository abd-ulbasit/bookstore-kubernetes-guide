# Bookstore policy as code, Kubernetes objects (Part 05 ch.07).
#
# Each rule states one line of the baseline from Part 01 ch.01, or one
# exposure the Pod Security levels do not cover. Every message starts with a
# rule ID (BK-POL-NNN) so a control can name the rule it expects to fire.
#
# Run it on a rendered overlay, from the repository root:
#   conftest test --policy full-guide/examples/bookstore/policy \
#     --all-namespaces <rendered.yaml>
#
# The same rules run as unit tests with `opa test`; see baseline_test.rego.
package bookstore.kubernetes

import rego.v1

# first_party is the registry prefix the Bookstore pushes its own images to.
# Its images carry the tag the build produced; every other image is pinned
# by digest.
first_party := "registry.example.com/bookstore/"

# pod_spec is the Pod spec of every kind that runs Pods. Only one of these
# rules matches a given input, because the kinds differ.
pod_spec := input.spec if input.kind == "Pod"

pod_spec := input.spec.template.spec if input.kind in {
	"Deployment", "StatefulSet", "DaemonSet", "Job",
}

pod_spec := input.spec.jobTemplate.spec.template.spec if input.kind == "CronJob"

# containers lists every container and init container of a Pod spec, with
# the object's own fields and its securityContext, if any.
containers contains c if {
	some c in pod_spec.containers
}

containers contains c if {
	some c in object.get(pod_spec, "initContainers", [])
}

# pod_sc is the Pod-level securityContext. A container-level field overrides
# the Pod-level one for the same setting, so every check reads the container
# first and falls back to the Pod.
pod_sc := object.get(pod_spec, "securityContext", {})

container_sc(c) := object.get(c, "securityContext", {})

deny contains msg if {
	some c in containers
	object.get(container_sc(c), "privileged", false) == true
	msg := sprintf("BK-POL-001 %s %s: container %s runs privileged", [input.kind, input.metadata.name, c.name])
}

deny contains msg if {
	some c in containers
	object.get(container_sc(c), "allowPrivilegeEscalation", true) != false
	msg := sprintf("BK-POL-002 %s %s: container %s allows privilege escalation", [input.kind, input.metadata.name, c.name])
}

deny contains msg if {
	some c in containers
	not "ALL" in object.get(object.get(container_sc(c), "capabilities", {}), "drop", [])
	msg := sprintf("BK-POL-003 %s %s: container %s does not drop ALL capabilities", [input.kind, input.metadata.name, c.name])
}

deny contains msg if {
	some c in containers
	not run_as_non_root(c)
	msg := sprintf("BK-POL-004 %s %s: container %s may run as root (runAsNonRoot is not true)", [input.kind, input.metadata.name, c.name])
}

run_as_non_root(c) if {
	object.get(container_sc(c), "runAsNonRoot", object.get(pod_sc, "runAsNonRoot", false)) == true
}

deny contains msg if {
	some c in containers
	not seccomp_ok(c)
	msg := sprintf("BK-POL-005 %s %s: container %s has no RuntimeDefault or Localhost seccomp profile", [input.kind, input.metadata.name, c.name])
}

seccomp_ok(c) if {
	profile := object.get(container_sc(c), "seccompProfile", object.get(pod_sc, "seccompProfile", {}))
	profile.type in {"RuntimeDefault", "Localhost"}
}

deny contains msg if {
	some c in containers
	object.get(container_sc(c), "readOnlyRootFilesystem", false) != true
	msg := sprintf("BK-POL-006 %s %s: container %s writes to its root filesystem", [input.kind, input.metadata.name, c.name])
}

# Host namespaces and hostPath are refused by the restricted level too; the
# policy states them so that a CI run fails before the cluster ever sees them.
deny contains msg if {
	pod_spec
	some field in {"hostNetwork", "hostPID", "hostIPC"}
	object.get(pod_spec, field, false) == true
	msg := sprintf("BK-POL-007 %s %s sets %s", [input.kind, input.metadata.name, field])
}

deny contains msg if {
	pod_spec
	some v in object.get(pod_spec, "volumes", [])
	v.hostPath
	msg := sprintf("BK-POL-007 %s %s mounts hostPath volume %s", [input.kind, input.metadata.name, v.name])
}

# A Pod that does not need the API server must not carry a token. A Pod that
# does gets its own ServiceAccount, and only then may it mount the token.
deny contains msg if {
	pod_spec
	object.get(pod_spec, "automountServiceAccountToken", true) != false
	not dedicated_sa
	msg := sprintf("BK-POL-008 %s %s mounts the default ServiceAccount token: set automountServiceAccountToken to false", [input.kind, input.metadata.name])
}

dedicated_sa if {
	object.get(pod_spec, "serviceAccountName", "default") != "default"
}

# Third-party images are pinned by digest. Every image is refused at the
# tag `latest`, including the Bookstore's own.
deny contains msg if {
	some c in containers
	not startswith(c.image, first_party)
	not contains(c.image, "@sha256:")
	msg := sprintf("BK-POL-009 %s %s: container %s uses %s, which is not pinned by digest", [input.kind, input.metadata.name, c.name, c.image])
}

deny contains msg if {
	some c in containers
	endswith(c.image, ":latest")
	msg := sprintf("BK-POL-009 %s %s: container %s uses the latest tag", [input.kind, input.metadata.name, c.name])
}

# A Service with externalIPs answers for those addresses on every node, so a
# tenant who can create Services can take traffic meant for another address.
deny contains msg if {
	input.kind == "Service"
	count(object.get(input.spec, "externalIPs", [])) > 0
	msg := sprintf("BK-POL-010 Service %s sets externalIPs", [input.metadata.name])
}

# A Namespace the Bookstore creates enforces restricted. The label is what
# makes Pod Security Admission refuse the Pods above in the cluster. A
# namespace below restricted is an exception only when it carries both
# annotations of the exception record (Part 05 ch.09): a reason and an expiry
# date. This rule checks that both are present; the 365-day window is checked
# by the admission rule in the cluster.
exception_annotations := {"security.example/exception-reason", "security.example/exception-expires"}

excepted_namespace if {
	ann := object.get(input.metadata, "annotations", {})
	every key in exception_annotations {
		ann[key]
	}
}

deny contains msg if {
	input.kind == "Namespace"
	level := object.get(object.get(input.metadata, "labels", {}), "pod-security.kubernetes.io/enforce", "")
	level != "restricted"
	not excepted_namespace
	msg := sprintf("BK-POL-011 Namespace %s enforces %q, not restricted", [input.metadata.name, level])
}
