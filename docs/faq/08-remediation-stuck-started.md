# FAQ: Why Is My Remediation Stuck in "Started" Phase?

## Question

Why is my remediation stuck in the "Started" phase and never completing?

## Answer

A remediation CR remaining in the "Started" phase indicates that the remediation process began but has not progressed to completion. Several issues can cause this.

### 1. API server unreachable from the target node

The SNR agent on the unhealthy node cannot update the remediation CR's status if it has lost connectivity to the API server. In this case, SNR falls back to peer health checks — the agent contacts other SNR agents to determine whether the problem is isolated or cluster-wide.

Check whether the node can reach the API server:

```bash
oc debug node/<node-name> -- chroot /host curl -sk https://api-int.<cluster>:6443/healthz
```

### 2. DaemonSet pods blocking drain

DaemonSet pods may prevent the node drain from completing. SNR handles this by adding the `out-of-service` taint to the node, which signals the Kubernetes scheduler and volume plugins to treat the node as permanently offline.

Check for pods still running on the node:

```bash
oc get pods --all-namespaces --field-selector spec.nodeName=<node-name>
```

### 3. PVC/storage issues

Persistent volumes attached to the node may block pod eviction. Pods with `ReadWriteOnce` PVCs cannot be rescheduled until the volume is detached from the original node.

### 4. Incorrect timeout units

If using `escalatingRemediations`, verify the timeout unit. A common mistake is specifying `600M` (600 minutes, approximately 10 hours) instead of `600s` (600 seconds, 10 minutes):

```yaml
# Wrong — 600 minutes
timeout: 600M

# Correct — 600 seconds
timeout: 600s
```

### Diagnostic steps

1. **Check the SNR agent logs** on the target node:

    ```bash
    oc logs <snr-agent-pod> -n openshift-operators
    ```

2. **Check the remediation CR status:**

    ```bash
    oc get selfnoderemediation -A -o yaml
    ```

3. **Verify network connectivity** of the target node to both the API server and peer nodes.

## Related Resources

- [SNR documentation](https://medik8s.io/remediation/self-node-remediation/self-node-remediation.html)
- [SNR GitHub repository](https://github.com/medik8s/self-node-remediation)
