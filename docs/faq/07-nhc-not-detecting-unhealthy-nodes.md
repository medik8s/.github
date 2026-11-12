# FAQ: Why Isn't NHC Detecting or Remediating My Unhealthy Node?

## Question

Why isn't NHC detecting or remediating my unhealthy node?

## Answer

Several common causes can prevent NHC from detecting unhealthy nodes or triggering remediation.

### 1. Selector mismatch

The `NodeHealthCheck` CR's selector does not match the target node's labels. Verify which nodes are targeted:

```bash
# Check node labels
oc get nodes --show-labels

# Check the NHC selector
oc get nodehealthcheck <nhc-name> -o jsonpath='{.spec.selector}'
```

Ensure the selector's `matchLabels` or `matchExpressions` match the labels on the nodes you expect to be monitored.

### 2. Duration not met

The unhealthy condition must persist for the configured duration before remediation is triggered. If a node flaps between healthy and unhealthy states, the timer resets each time the condition clears.

Check the configured duration in the NHC CR:

```bash
oc get nodehealthcheck <nhc-name> -o yaml | grep -A10 unhealthyConditions
```

### 3. minHealthy violation

NHC will not remediate a node if doing so would bring the number of healthy nodes below the `minHealthy` threshold. This is a safety mechanism to prevent cascading remediations.

```bash
# Check minHealthy setting
oc get nodehealthcheck <nhc-name> -o jsonpath='{.spec.minHealthy}'

# Check current healthy node count
oc get nodes -o wide
```

### 4. Timeout too short for escalatingRemediations

If using `escalatingRemediations`, ensure the timeout is at least 5–10 minutes. SNR remediation can take 3 or more minutes to complete (reboot + node recovery). A timeout that is too short causes NHC to escalate before the first remediator finishes.

If you only need one remediation method, consider using `remediationTemplate` directly instead of `escalatingRemediations` to simplify the configuration.

### Diagnostic commands

```bash
# Check NHC status and conditions
oc get nodehealthcheck -A -o yaml

# Check for active remediations
oc get selfnoderemediation -A
oc get fenceagentsremediation -A
oc get machinedeletionremediation -A

# Check NHC controller logs
oc logs deployment/node-healthcheck-controller-manager -n openshift-operators
```

## Related Resources

- [NHC documentation](https://medik8s.io/failure-detection/node-health-check/node-health-check.html)
- [NHC GitHub repository](https://github.com/medik8s/node-healthcheck-operator)
