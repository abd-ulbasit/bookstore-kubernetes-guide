# Unit tests for baseline.rego. Run them from the repository root:
#   opa test full-guide/examples/bookstore/policy -v
#
# Each test states one fact about a Pod or a Service. The good Deployment is
# the baseline from Part 01 ch.01, field for field; every bad input changes
# one field from it.
package bookstore.kubernetes

import rego.v1

good_deployment := {
	"apiVersion": "apps/v1",
	"kind": "Deployment",
	"metadata": {"name": "catalog", "namespace": "bookstore"},
	"spec": {
		"replicas": 2,
		"selector": {"matchLabels": {"app": "catalog"}},
		"template": {
			"metadata": {"labels": {"app": "catalog"}},
			"spec": {
				"automountServiceAccountToken": false,
				"securityContext": {
					"runAsNonRoot": true,
					"runAsUser": 65532,
					"runAsGroup": 65532,
					"seccompProfile": {"type": "RuntimeDefault"},
				},
				"containers": [{
					"name": "app",
					"image": "registry.example.com/bookstore/catalog:1.0.0",
					"securityContext": {
						"allowPrivilegeEscalation": false,
						"readOnlyRootFilesystem": true,
						"capabilities": {"drop": ["ALL"]},
					},
					"resources": {
						"requests": {"cpu": "100m", "memory": "64Mi"},
						"limits": {"memory": "128Mi"},
					},
					"volumeMounts": [{"name": "tmp", "mountPath": "/tmp"}],
				}],
				"volumes": [{"name": "tmp", "emptyDir": {}}],
			},
		},
	},
}

# object.union merges nested objects, so a changed securityContext must not
# meet the good one. The helpers remove it first, then put the new one in.
good_pod_spec := good_deployment.spec.template.spec

good_container := good_pod_spec.containers[0]

with_pod_spec(patch) := object.union(good_deployment, {"spec": {"template": {"spec": patch}}})

with_container(sc) := with_pod_spec({"containers": [object.union(
	object.remove(good_container, ["securityContext"]),
	{"securityContext": sc},
)]})

with_pod_sc(psc) := with_pod_spec({"securityContext": psc})

test_good_deployment_passes if {
	count(deny) == 0 with input as good_deployment
}

test_privileged_container_fails if {
	bad := with_container({
		"privileged": true,
		"allowPrivilegeEscalation": false,
		"readOnlyRootFilesystem": true,
		"capabilities": {"drop": ["ALL"]},
	})
	some m in deny with input as bad
	startswith(m, "BK-POL-001")
}

test_privilege_escalation_fails if {
	bad := with_container({
		"readOnlyRootFilesystem": true,
		"capabilities": {"drop": ["ALL"]},
	})
	some m in deny with input as bad
	startswith(m, "BK-POL-002")
}

test_capability_not_dropped_fails if {
	bad := with_container({
		"allowPrivilegeEscalation": false,
		"readOnlyRootFilesystem": true,
		"capabilities": {"drop": ["NET_RAW"]},
	})
	some m in deny with input as bad
	startswith(m, "BK-POL-003")
}

test_root_user_fails if {
	bad := with_pod_sc({"runAsNonRoot": false, "seccompProfile": {"type": "RuntimeDefault"}})
	some m in deny with input as bad
	startswith(m, "BK-POL-004")
}

test_container_level_runAsNonRoot_overrides_pod_level if {
	# The Pod sets runAsNonRoot to false, and the container sets it to true.
	# The container's value wins, so the rule does not fire.
	pod_false := with_pod_sc({"runAsNonRoot": false, "seccompProfile": {"type": "RuntimeDefault"}})
	ok := with_pod_spec({
		"securityContext": {"runAsNonRoot": false, "seccompProfile": {"type": "RuntimeDefault"}},
		"containers": [object.union(object.remove(good_container, ["securityContext"]), {"securityContext": {
			"runAsNonRoot": true,
			"allowPrivilegeEscalation": false,
			"readOnlyRootFilesystem": true,
			"capabilities": {"drop": ["ALL"]},
		}})],
	})
	count({m | some m in deny with input as pod_false; startswith(m, "BK-POL-004")}) == 1
	count({m | some m in deny with input as ok; startswith(m, "BK-POL-004")}) == 0
}

test_unconfined_seccomp_fails if {
	bad := with_container({
		"allowPrivilegeEscalation": false,
		"readOnlyRootFilesystem": true,
		"capabilities": {"drop": ["ALL"]},
		"seccompProfile": {"type": "Unconfined"},
	})
	some m in deny with input as bad
	startswith(m, "BK-POL-005")
}

test_writable_root_fails if {
	bad := with_container({
		"allowPrivilegeEscalation": false,
		"readOnlyRootFilesystem": false,
		"capabilities": {"drop": ["ALL"]},
	})
	some m in deny with input as bad
	startswith(m, "BK-POL-006")
}

test_host_namespace_fails if {
	bad := with_pod_spec({"hostPID": true})
	some m in deny with input as bad
	startswith(m, "BK-POL-007")
}

test_hostPath_fails if {
	bad := with_pod_spec({"volumes": [{"name": "root", "hostPath": {"path": "/"}}]})
	some m in deny with input as bad
	startswith(m, "BK-POL-007")
}

test_default_token_mount_fails if {
	bad := with_pod_spec({"automountServiceAccountToken": true})
	some m in deny with input as bad
	startswith(m, "BK-POL-008")
}

test_token_mount_allowed_with_dedicated_sa if {
	ok := with_pod_spec({"automountServiceAccountToken": true, "serviceAccountName": "catalog"})
	count({m | some m in deny with input as ok; startswith(m, "BK-POL-008")}) == 0
}

test_unpinned_third_party_image_fails if {
	bad := with_pod_spec({"containers": [object.union(good_container, {"image": "redis:7"})]})
	some m in deny with input as bad
	startswith(m, "BK-POL-009")
}

test_latest_tag_fails if {
	bad := with_pod_spec({"containers": [object.union(
		good_container,
		{"image": "registry.example.com/bookstore/catalog:latest"},
	)]})
	some m in deny with input as bad
	startswith(m, "BK-POL-009")
}

test_service_external_ips_fails if {
	bad := {
		"apiVersion": "v1",
		"kind": "Service",
		"metadata": {"name": "catalog", "namespace": "bookstore"},
		"spec": {"externalIPs": ["203.0.113.10"], "ports": [{"port": 80}]},
	}
	some m in deny with input as bad
	startswith(m, "BK-POL-010")
}

# namespace_at is a Namespace object that enforces the given level. The tests
# pass the level in, so each one reads as the case it checks.
namespace_at(name, level) := {
	"apiVersion": "v1",
	"kind": "Namespace",
	"metadata": {"name": name, "labels": {"pod-security.kubernetes.io/enforce": level}},
}

# namespace_with_record is the same Namespace carrying the exception record.
namespace_with_record(name, level) := object.union(namespace_at(name, level), {"metadata": {"annotations": {
	"security.example/exception-reason": "Host mounts for the Falco driver.",
	"security.example/exception-expires": "2027-06-30",
}}})

test_namespace_not_restricted_fails if {
	some m in deny with input as namespace_at("bookstore", "baseline")
	startswith(m, "BK-POL-011")
}

test_excepted_namespace_passes if {
	count(deny) == 0 with input as namespace_with_record("falco", "privileged")
}

test_restricted_namespace_passes if {
	count(deny) == 0 with input as namespace_at("bookstore", "restricted")
}
