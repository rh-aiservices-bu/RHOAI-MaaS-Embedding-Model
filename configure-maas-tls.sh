#!/usr/bin/env bash
# Configure TLS between Authorino and the MaaS API gateway.
# Ref: OpenShift AI 3.4 "Configure TLS for Models-as-a-Service".
set -euo pipefail

NS=kuadrant-system

# 1. Generate a service-serving cert for Authorino (service-ca-operator stores
#    it in the authorino-server-cert secret).
oc annotate service authorino-authorino-authorization \
  -n "$NS" \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  --overwrite

# 2. Enable the Authorino TLS listener, referencing the generated cert.
oc patch authorino authorino -n "$NS" --type=merge --patch '
{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": {
          "name": "authorino-server-cert"
        }
      }
    }
  }
}'

# 3. Point Authorino at the cluster service-CA bundle for cert validation.
oc -n "$NS" set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt

# 4. Ensure the Gateway has the TLS-bootstrap annotation (already set in
#    maas-gateway.yaml; re-applied here for idempotency).
oc annotate gateway maas-default-gateway \
  -n openshift-ingress \
  security.opendatahub.io/authorino-tls-bootstrap="true" \
  --overwrite
