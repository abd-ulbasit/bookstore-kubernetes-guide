# Bookstore policy as code, Terraform plans (Part 05 ch.07).
#
# The input is the JSON from `terraform show -json plan.out`. The rules read
# the namespaces the plan creates or changes, and refuse one that does not
# enforce the restricted Pod Security level. The same level is what the
# cluster enforces at admission, so a plan that would fail there fails here,
# before anyone applies it.
#
# Run it from the repository root:
#   conftest test --policy full-guide/examples/bookstore/policy \
#     --all-namespaces full-guide/examples/bookstore/policy/terraform/plan.json
package bookstore.terraform

import rego.v1

# namespaces is every namespace the plan leaves in place, after the change.
# A delete has no "after" value, so it is skipped.
namespaces contains rc if {
	some rc in input.resource_changes
	rc.type == "kubernetes_namespace_v1"
	rc.change.after != null
}

deny contains msg if {
	some rc in namespaces
	labels := object.get(rc.change.after.metadata[0], "labels", {})
	level := object.get(labels, "pod-security.kubernetes.io/enforce", "")
	level != "restricted"
	msg := sprintf("BK-TF-001 %s enforces %q, not restricted", [rc.address, level])
}
