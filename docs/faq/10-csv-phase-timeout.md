# FAQ: Operator Installation Stuck With PodSecurity Violations or ImagePullBackOff

## Question

My operator installation is stuck in CSV phase/timeout with PodSecurity violations or ImagePullBackOff. How do I fix it?

## Answer

Two common issues can cause operator installation to stall during the CSV phase.

### PodSecurity violations

Clusters with enforced Pod Security Admission (PSA) may reject operator pods that require elevated privileges. Common violation messages include:

- `allowPrivilegeEscalation != false`
- `runAsNonRoot != true`
- `missing seccompProfile`

Some medik8s operators (notably SNR) require root access to interact with hardware watchdog devices. These operators need namespace-level PSA exemptions.

**Diagnostic steps:**

1. Check namespace security labels:

    ```bash
    oc get namespace <operator-namespace> -o yaml | grep pod-security
    ```

2. Check pod events for PSA violations:

    ```bash
    oc describe pod <operator-pod> -n <operator-namespace>
    ```

### ImagePullBackOff

This error usually indicates that the container runtime cannot pull the operator image. Common causes:

- **DNS resolution failures** for the image registry
- **Network connectivity issues** between nodes and the registry
- **Incorrect image references** in the CSV or subscription

**Diagnostic steps:**

1. Check CSV status:

    ```bash
    oc get csv -n <namespace>
    ```

2. Check pod events:

    ```bash
    oc describe pod <operator-pod> -n <namespace>
    ```

3. Verify image accessibility from a node:

    ```bash
    oc debug node/<node> -- chroot /host podman pull <image>
    ```

4. Check namespace security labels:

    ```bash
    oc get namespace <ns> -o yaml | grep pod-security
    ```

### General troubleshooting

Review the operator's `ClusterServiceVersion` for detailed status:

```bash
oc get csv -n <namespace> -o yaml | grep -A20 'status:'
```

## Related Resources

- [Kubernetes Pod Security Admission documentation](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [OpenShift Pod Security documentation](https://docs.openshift.com/container-platform/latest/authentication/understanding-and-managing-pod-security-admission.html)
