# FAQ: Can I Use NHC and SNR on Schedulable Control Plane Nodes?

## Question

Can I use NHC and SNR on schedulable control plane nodes?

## Answer

Yes. Both NHC and SNR support schedulable control plane nodes and are tested in that configuration. Both operators include tolerations for control plane taints by default.

### Requirements and best practices

1. **Create separate `NodeHealthCheck` CRs** for control plane and worker nodes. Do not use a single NHC CR that targets both.

2. **Use the correct node selector** for control plane nodes:

    ```yaml
    spec:
      selector:
        matchExpressions:
          - key: node-role.kubernetes.io/control-plane
            operator: Exists
    ```

    On older clusters, use `node-role.kubernetes.io/master` instead.

3. **Set `minHealthy` explicitly** to maintain etcd quorum. For a standard 3-node control plane:

    ```yaml
    spec:
      minHealthy: 2        # absolute count
      # or
      minHealthy: "67%"    # percentage form
    ```

    This prevents NHC from remediating a control plane node if doing so would risk losing etcd quorum.

4. **NHC enforces an additional safety limit:** only one control plane node can be remediated at a time, regardless of the `minHealthy` setting.

5. **Disable SNR before planned control plane maintenance.** If you drain or cordon a control plane node without disabling SNR, the watchdog agent eviction may trigger a cascading reboot. See the [maintenance FAQ](04-preventing-reboots-maintenance.md) for details.

## Related Resources

- [Node Health Check documentation](https://medik8s.io/failure-detection/node-health-check/node-health-check.html)
- [SNR documentation](https://medik8s.io/remediation/self-node-remediation/self-node-remediation.html)
