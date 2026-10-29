# FAQ: Why Is My CR Configuration Being Rejected by Validation?

## Question

Why is my CR configuration being rejected by validation?

## Answer

The medik8s operators use validating webhooks and CRD validation rules to prevent invalid configurations at admission time. Several common issues can trigger validation errors.

### Strategy name in template

SNR template names include the remediation strategy. You must reference the correct template for your desired strategy:

```bash
# List available templates
oc get selfnoderemediationtemplates -A
```

For example, the default template is typically named `self-node-remediation-automatic-strategy-template`. Using an incorrect or outdated name causes a validation error.

### NHC validating webhook

NHC validates `NodeHealthCheck` CR configurations at admission time. The webhook checks for:

- **Valid node conditions** in `unhealthyConditions`
- **Valid label selectors** in `spec.selector`
- **Existing remediation template references** — the referenced template CR must exist in the specified namespace
- **Consistent `escalatingRemediations`** configuration (valid order, reasonable timeouts)

Check the webhook configuration:

```bash
oc get validatingwebhookconfigurations | grep -i medik8s
```

### CRD defaults

Some fields have CRD-level defaults that are applied automatically when not specified. Be aware that the effective configuration may differ from what you explicitly set if defaults fill in missing fields.

### Diagnostic steps

1. **Read the full error message** — admission webhook errors typically include the specific validation rule that failed.

2. **Check webhook configurations:**

    ```bash
    oc get validatingwebhookconfigurations | grep -i medik8s
    oc get mutatingwebhookconfigurations | grep -i medik8s
    ```

3. **Inspect the CRD schema** for allowed values:

    ```bash
    oc explain nodehealthcheck.spec
    oc explain selfnoderemediationtemplate.spec
    ```

4. **Verify the template exists:**

    ```bash
    oc get selfnoderemediationtemplates -A
    oc get fenceagentsremediationtemplates -A
    ```

## Related Resources

- [NHC documentation](https://medik8s.io/failure-detection/node-health-check/node-health-check.html)
- [SNR documentation](https://medik8s.io/remediation/self-node-remediation/self-node-remediation.html)
