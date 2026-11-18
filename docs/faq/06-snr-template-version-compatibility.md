# FAQ: Why Do I Get a RemediationTemplateNotFound Error?

## Question

Why do I get a `RemediationTemplateNotFound` error when NHC tries to remediate a node?

## Answer

This error occurs when the `NodeHealthCheck` CR references an SNR remediation template name that does not exist in the cluster. The template name changed between SNR versions:

| SNR version / OCP version | Template name |
| --- | --- |
| Poison Pill (pre-rename) | `poison-pill-default-template` |
| SNR early versions (OCP < 4.14) | `self-node-remediation-resource-deletion-template` |
| SNR current versions (OCP 4.14+) | `self-node-remediation-automatic-strategy-template` |

### How to fix

1. **Check which templates are available** in your cluster:

    ```bash
    oc get selfnoderemediationtemplates -A
    ```

2. **Update the `NodeHealthCheck` CR** to reference the correct template name:

    ```yaml
    spec:
      remediationTemplate:
        apiVersion: self-node-remediation.medik8s.io/v1alpha1
        kind: SelfNodeRemediationTemplate
        name: self-node-remediation-automatic-strategy-template
        namespace: openshift-operators
    ```

    Or if using `escalatingRemediations`:

    ```yaml
    spec:
      escalatingRemediations:
        - remediationTemplate:
            apiVersion: self-node-remediation.medik8s.io/v1alpha1
            kind: SelfNodeRemediationTemplate
            name: self-node-remediation-automatic-strategy-template
            namespace: openshift-operators
          order: 0
          timeout: 300s
    ```

3. **Verify the fix:**

    ```bash
    oc get nodehealthcheck -A -o yaml | grep -A5 remediationTemplate
    ```

## Related Resources

- [SNR documentation](https://medik8s.io/remediation/self-node-remediation/self-node-remediation.html)
- [NHC documentation](https://medik8s.io/failure-detection/node-health-check/node-health-check.html)
