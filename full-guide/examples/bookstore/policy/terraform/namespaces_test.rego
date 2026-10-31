# Unit tests for namespaces.rego, on a hand-written slice of plan JSON. The
# real plan is checked by conftest against plan.json; see the chapter.
package bookstore.terraform

import rego.v1

namespace_change(address, level) := {"resource_changes": [{
	"address": address,
	"type": "kubernetes_namespace_v1",
	"name": "x",
	"change": {
		"actions": ["create"],
		"after": {"metadata": [{"name": "x", "labels": {"pod-security.kubernetes.io/enforce": level}}]},
	},
}]}

test_restricted_namespace_passes if {
	count(deny) == 0 with input as namespace_change("kubernetes_namespace_v1.bookstore", "restricted")
}

test_privileged_namespace_fails if {
	some m in deny with input as namespace_change("kubernetes_namespace_v1.legacy", "privileged")
	startswith(m, "BK-TF-001 kubernetes_namespace_v1.legacy")
}

test_missing_label_fails if {
	bad := {"resource_changes": [{
		"address": "kubernetes_namespace_v1.bare",
		"type": "kubernetes_namespace_v1",
		"name": "bare",
		"change": {"actions": ["create"], "after": {"metadata": [{"name": "bare"}]}},
	}]}
	some m in deny with input as bad
	startswith(m, "BK-TF-001 kubernetes_namespace_v1.bare")
}

test_deleted_namespace_is_skipped if {
	gone := {"resource_changes": [{
		"address": "kubernetes_namespace_v1.old",
		"type": "kubernetes_namespace_v1",
		"name": "old",
		"change": {"actions": ["delete"], "after": null},
	}]}
	count(deny) == 0 with input as gone
}

test_other_resource_types_are_skipped if {
	other := {"resource_changes": [{
		"address": "kubernetes_config_map_v1.x",
		"type": "kubernetes_config_map_v1",
		"name": "x",
		"change": {"actions": ["create"], "after": {"metadata": [{"name": "x"}]}},
	}]}
	count(deny) == 0 with input as other
}
