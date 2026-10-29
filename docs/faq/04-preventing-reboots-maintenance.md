# FAQ: How Do I Prevent Node Reboots During Maintenance?

## Question

Why does my node reboot during maintenance, and how do I prevent it?

## Answer

When a node is drained for maintenance, the SNR agent pod is evicted along with other workloads. Once evicted, the agent stops petting the hardware watchdog timer. When the timer expires, the node reboots — even though the drain was intentional.

### Solution: Use NMO (Node Maintenance Operator)

The recommended approach is to use the [Node Maintenance Operator](https://github.com/medik8s/node-maintenance-operator) (NMO). When NMO places a node into maintenance mode, it automatically adds the annotation:

```
remediation.medik8s.io/exclude-from-remediation: "true"
```

This annotation has two effects:

1. **NHC** will not create remediation CRs for the annotated node.
2. **SNR** removes the agent pod from the node via DaemonSet `nodeAffinity`, which cleanly releases the watchdog device before eviction.

### Manual alternative

If you are not using NMO, you can manually add the annotation before draining:

```bash
oc annotate node <node-name> remediation.medik8s.io/exclude-from-remediation=true --overwrite
```

After maintenance is complete and the node is uncordoned, remove the annotation:

```bash
oc annotate node <node-name> remediation.medik8s.io/exclude-from-remediation-
```

> **Important:** Always apply the annotation **before** starting the drain. If you drain first, the SNR agent may already be evicted and the watchdog timer may already be counting down.

## Related Resources

- [Node Maintenance Operator documentation](https://medik8s.io/remediation/node-maintenance-operator/node-maintenance-operator.html)
- [NMO GitHub repository](https://github.com/medik8s/node-maintenance-operator)
