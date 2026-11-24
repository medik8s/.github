# FAQ: How Do I Inject a Custom CA Certificate for FAR's fence_redfish Agent?

## Question

How do I inject a custom CA certificate for FAR's `fence_redfish` agent?

## Answer

The Python-based `fence_redfish` agent does not use the system CA trust store. Adding the CA to the cluster proxy (`Proxy/cluster .spec.trustedCA`) does not make it available to the fence agent. You must mount the CA bundle directly into the FAR operator pod.

### Step 1: Create a Trusted CA ConfigMap

Create a `ConfigMap` with the `config.openshift.io/inject-trusted-cabundle` label. OpenShift's certificate injection controller will populate it with the cluster's combined CA bundle:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: far-trusted-ca
  namespace: openshift-workload-availability
  labels:
    config.openshift.io/inject-trusted-cabundle: "true"
data: {}
```

Apply it:

```bash
oc apply -f far-trusted-ca-configmap.yaml
```

### Step 2: Edit the FAR Subscription to mount the CA bundle

Modify the FAR `Subscription` to add environment variables and volume mounts that point the Python SSL libraries to the injected CA bundle:

```yaml
spec:
  config:
    env:
    - name: REQUESTS_CA_BUNDLE
      value: /etc/far-ca/ca-bundle.crt
    - name: SSL_CERT_FILE
      value: /etc/far-ca/ca-bundle.crt
    volumes:
    - name: far-trusted-ca-vol
      configMap:
        name: far-trusted-ca
    volumeMounts:
    - name: far-trusted-ca-vol
      mountPath: /etc/far-ca
      readOnly: true
```

This configuration:

- Sets `REQUESTS_CA_BUNDLE` for the Python `requests` library
- Sets `SSL_CERT_FILE` for the underlying OpenSSL library
- Mounts the injected CA bundle at `/etc/far-ca/ca-bundle.crt`

### Persistence across upgrades

Because the volume mount and environment variables are configured in the `Subscription` resource, they persist across operator upgrades. OLM applies the subscription's `config` section to every `Deployment` it manages for that operator.

### Native support

A feature request exists (RHWA-92) for native CA certificate support in FAR, which would eliminate the need for manual subscription editing.

## Related Resources

- [FAR GitHub repository](https://github.com/medik8s/fence-agents-remediation)
- [OpenShift certificate injection documentation](https://docs.openshift.com/container-platform/latest/networking/configuring-a-custom-pki.html)
