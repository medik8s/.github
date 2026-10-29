# FAQ: Do NHC and SNR Have to Be Used Together?

## Question

Do Node Health Check (NHC) and Self Node Remediation (SNR) have to be used together?

## Answer

No. NHC and SNR are independent components that can be deployed and used separately.

**NHC** is a generic health detection framework that monitors node conditions and triggers remediation. It works with multiple remediators through a pluggable interface:

- **SNR** (Self Node Remediation) — watchdog-based, reboots unhealthy nodes
- **FAR** (Fence Agents Remediation) — uses IPMI/Redfish fence agents
- **MDR** (Machine Deletion Remediation) — deletes the Machine API object to trigger re-provisioning

The remediator is configured in the `NodeHealthCheck` CR via `remediationTemplate` (single method) or `escalatingRemediations` (try multiple methods in sequence with timeouts).

**SNR has a unique capability:** it can act independently without NHC. If an SNR agent loses both API server connectivity and peer connectivity, it will autonomously reboot the node. This self-remediation behavior operates outside of NHC's detection logic.

> **Warning:** If you do not plan to use SNR for remediation, uninstall it entirely. Leaving SNR installed but unused can cause unexpected autonomous reboots when a node experiences network issues.

## Related Resources

- [Node Health Check documentation](https://medik8s.io/failure-detection/node-health-check/node-health-check.html)
- [SNR documentation](https://medik8s.io/remediation/self-node-remediation/self-node-remediation.html)
- [FAR documentation](https://medik8s.io/remediation/fence-agents-remediation/fence-agents-remediation.html)
- [MDR documentation](https://medik8s.io/remediation/machine-deletion-remediation/machine-deletion-remediation.html)
