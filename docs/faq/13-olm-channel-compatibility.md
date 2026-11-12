# FAQ: How Do I Prevent Operator Auto-Updates to Incompatible OCP Versions?

## Question

How do I prevent operator auto-updates to incompatible OCP versions?

## Answer

OLM (Operator Lifecycle Manager) uses CSV annotations to control operator compatibility with OpenShift versions. Understanding these annotations helps prevent both incompatible operator upgrades and blocked cluster upgrades.

### Key CSV annotations

| Annotation | Purpose |
| --- | --- |
| `olm.openShiftMaxVersion` | Maximum compatible OCP version. Blocks cluster upgrades if an incompatible operator is detected. |
| `olm.skipRange` | Controls automatic version skipping during operator upgrades. |

### Diagnosing compatibility issues

Check the OLM cluster operator status:

```bash
oc describe clusteroperator operator-lifecycle-manager
```

A blocking message looks like:

```
ClusterServiceVersions blocking cluster upgrade:
openshift-operators/poison-pill.v0.3.1 is incompatible with
OpenShift minor versions greater than 4.10
```

This means the installed operator version has a `maxVersion` annotation that is lower than the target OCP version, and OLM will block the cluster upgrade until the operator is updated or removed.

### Preventing issues

1. **Check your subscription approval strategy:**

    ```bash
    oc get subscriptions -A -o yaml | grep -A2 installPlanApproval
    ```

    - `Automatic` — OLM installs new operator versions as they become available. This can cause compatibility issues if a new version is released that targets a different OCP range.
    - `Manual` — You must approve each upgrade explicitly. This gives you control but requires monitoring for updates.

2. **Review installed CSV annotations:**

    ```bash
    oc get csv -n <namespace> -o jsonpath='{.metadata.annotations}' | python3 -m json.tool | grep olm
    ```

3. **Before a cluster upgrade**, verify all operators are compatible with the target OCP version:

    ```bash
    oc get csv -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,MAX_VERSION:.metadata.annotations.olm\.maxOpenShiftVersion'
    ```

### Resolution

If an operator blocks a cluster upgrade:

- Update the operator to a version compatible with the target OCP version.
- If no compatible version is available, remove the operator before upgrading the cluster.
- Consider switching the subscription channel to match your target OCP version.

## Related Resources

- [OLM documentation](https://olm.operatorframework.io/)
- [OpenShift Operator compatibility documentation](https://docs.openshift.com/container-platform/latest/operators/admin/olm-upgrading-operators.html)
