# FAQ: How Do I Troubleshoot Unexpected Node Reboots?

## Question

How do I troubleshoot unexpected node reboots?

## Answer

When a node reboots unexpectedly, collect logs from multiple components to identify whether SNR or another mechanism was responsible.

### 1. Check SNR agent logs on the rebooted node

Look for the message `"we are unhealthy, triggering a reboot"`:

```bash
oc logs -p <snr-agent-pod-name> -n openshift-operators
```

The `-p` flag retrieves logs from the previous container instance (before the reboot).

### 2. Check SNR manager (Deployment) logs

The manager processes remediation CRs and coordinates recovery:

```bash
oc logs deployment/self-node-remediation-controller-manager -n openshift-operators
```

### 3. Check NHC active pod logs

Verify whether NHC detected unhealthy conditions and created a remediation CR:

```bash
oc logs deployment/node-healthcheck-controller-manager -n openshift-operators
```

### 4. Check BMC/iDRAC logs

If the node has a baseboard management controller, check its event log. A watchdog timer reset event is a strong indicator of SNR involvement.

### 5. Check remediation status

List all active and completed remediations:

```bash
oc get selfnoderemediation -A
```

### 6. Check events

Review recent events in the workload availability namespace:

```bash
oc get events -n openshift-workload-availability --sort-by='.lastTimestamp'
```

### 7. Check kubelet logs

Inspect the kubelet journal on the affected node for errors leading up to the reboot:

```bash
oc debug node/$NODE -- chroot /host journalctl -u kubelet -n 100
```

### Summary checklist

| Component | What to look for |
| --- | --- |
| SNR agent | "we are unhealthy, triggering a reboot" |
| SNR manager | Remediation CR processing, status updates |
| NHC | Unhealthy condition detection, CR creation |
| BMC/iDRAC | Watchdog timer reset events |
| kubelet | Pre-reboot errors or OOM events |

## Related Resources

- [SNR GitHub repository](https://github.com/medik8s/self-node-remediation)
- [NHC GitHub repository](https://github.com/medik8s/node-healthcheck-operator)
