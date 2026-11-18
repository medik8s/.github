# FAQ: Why Did All My Nodes Reboot When I Uninstalled SNR?

## Question

Why did all my nodes reboot when I uninstalled Self Node Remediation (SNR)?

## Answer

This is a known issue caused by incorrect uninstallation order. If the SNR Operator CSV is removed **before** the `SelfNodeRemediationConfig` CR, the SNR agent DaemonSet continues running unsupervised. The orphaned agents' watchdog timers expire because no controller is petting them, triggering reboots on every node where an agent is running.

### Correct uninstallation procedure (order matters)

1. **Disable remediation** to prevent new remediations from triggering:

    ```bash
    oc patch selfnoderemediationconfig config \
      -p '{"spec":{"isRemediationEnabled":false}}' --type=merge
    ```

2. **Remove finalizers** from all `SelfNodeRemediation` CRs.

3. **Delete the `SelfNodeRemediationConfig` CR** while the operator is still running. This step is critical — it allows the operator to cleanly remove the DaemonSet and release the watchdog devices on every node.

4. **Delete remaining `SelfNodeRemediation` CRs.**

5. **Finally, uninstall the SNR Operator** from OperatorHub.

> **Important:** Never remove the operator subscription or CSV before completing steps 1–4. The operator must be running to orchestrate a clean shutdown of the watchdog agents.

## Related Resources

- [Self Node Remediation documentation](https://medik8s.io/remediation/self-node-remediation/self-node-remediation.html)
- [SNR GitHub repository](https://github.com/medik8s/self-node-remediation)
