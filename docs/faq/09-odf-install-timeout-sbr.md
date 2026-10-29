# FAQ: ODF Installation Is Timing Out When Setting Up Storage-Based Remediation

## Question

ODF installation is timing out when setting up Storage-Based Remediation. What should I do?

## Answer

OpenShift Data Foundation (ODF) installation can be slow, especially in resource-constrained environments. Storage-Based Remediation (SBR) depends on ODF because it uses the storage CSI (Container Storage Interface) for its fencing mechanism.

### Common causes of ODF installation timeouts

- **Insufficient resources:** ODF requires substantial CPU, memory, and storage across multiple nodes. Ensure your cluster meets the [minimum resource requirements](https://docs.openshift.com/container-platform/latest/storage/persistent_storage/persistent-storage-ocs.html).
- **Slow provisioning:** The installation involves multiple operators (ODF, Rook-Ceph, NooBaa) and can take 30 minutes or longer to complete.
- **Storage backend issues:** The underlying storage provider must be healthy and responsive.

### Troubleshooting steps

1. **Check ODF operator pod status:**

    ```bash
    oc get pods -n openshift-storage
    ```

2. **Check CSV (ClusterServiceVersion) status:**

    ```bash
    oc get csv -n openshift-storage
    ```

    Look for `Succeeded` phase. If stuck in `Installing` or `Pending`, check the CSV events.

3. **Verify resource availability** on nodes designated for ODF:

    ```bash
    oc describe nodes | grep -A5 "Allocated resources"
    ```

4. **Check events** for errors or warnings:

    ```bash
    oc get events -n openshift-storage --sort-by='.lastTimestamp'
    ```

5. **Check StorageCluster status:**

    ```bash
    oc get storagecluster -n openshift-storage -o yaml
    ```

### Note on SBR and storage CSI

SBR uses storage CSI for its fencing operation — it writes a "poison pill" to shared storage that the unhealthy node reads on recovery, preventing it from rejoining the cluster with stale data. Ensure your storage provider supports the required CSI features (volume access modes, storage classes) before deploying SBR.

## Related Resources

- [SBR GitHub repository](https://github.com/medik8s/storage-based-remediation)
- [ODF documentation](https://docs.openshift.com/container-platform/latest/storage/persistent_storage/persistent-storage-ocs.html)
