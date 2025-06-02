#!/bin/bash
set -e

USER="$1"
NAMESPACE="$2"
EMAIL="$3"
KIND_CONTAINER="multi-node-cluster-control-plane"
OUTPUT_DIR="./$USER"

if [[ -z "$USER" || -z "$NAMESPACE" || -z "$EMAIL" ]]; then
  echo "Usage: $0 <username> <namespace> <email>"
  exit 1
fi

echo "👤 Creating user: $USER for namespace: $NAMESPACE"
mkdir -p "$OUTPUT_DIR"

# Check if Kind container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${KIND_CONTAINER}$"; then
  echo "❌ Kind control plane container '$KIND_CONTAINER' not found!"
  exit 1
fi

# Generate key and CSR
openssl genrsa -out "$OUTPUT_DIR/$USER.key" 2048
openssl req -new -key "$OUTPUT_DIR/$USER.key" -out "$OUTPUT_DIR/$USER.csr" -subj "/CN=$USER/O=$NAMESPACE-user"

# Copy CSR to container
docker cp "$OUTPUT_DIR/$USER.csr" "$KIND_CONTAINER:/var/tmp/$USER.csr"

# Sign CSR inside the Kind container
docker exec "$KIND_CONTAINER" openssl x509 -req -in "/var/tmp/$USER.csr" \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca.key \
  -CAcreateserial \
  -out "/var/tmp/$USER.crt" -days 365

# Copy signed cert back
docker cp "$KIND_CONTAINER:/var/tmp/$USER.crt" "$OUTPUT_DIR/$USER.crt"

# Get cluster info
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$OUTPUT_DIR/ca.crt"

# Generate kubeconfig
KUBECONFIG_FILE="$OUTPUT_DIR/$USER.kubeconfig"

kubectl config --kubeconfig="$KUBECONFIG_FILE" set-cluster "$CLUSTER_NAME" \
  --server="$CLUSTER_SERVER" \
  --certificate-authority="$OUTPUT_DIR/ca.crt" \
  --embed-certs=true

kubectl config --kubeconfig="$KUBECONFIG_FILE" set-credentials "$USER" \
  --client-certificate="$OUTPUT_DIR/$USER.crt" \
  --client-key="$OUTPUT_DIR/$USER.key" \
  --embed-certs=true

kubectl config --kubeconfig="$KUBECONFIG_FILE" set-context "$USER-context" \
  --cluster="$CLUSTER_NAME" \
  --user="$USER" \
  --namespace="$NAMESPACE"

kubectl config --kubeconfig="$KUBECONFIG_FILE" use-context "$USER-context"

# Restrict RBAC to namespace
kubectl create role "$USER-role" \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=pods,services,deployments,secrets \
  --namespace="$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create rolebinding "$USER-binding" \
  --role="$USER-role" \
  --user="$USER" \
  --namespace="$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Set file permission
chmod 600 "$KUBECONFIG_FILE"

# Prepare email body
EMAIL_BODY=$(cat <<EOF
Hi $USER,

Your kubeconfig file for accessing the Kubernetes cluster namespace '$NAMESPACE' is attached.

To use it, save the attached kubeconfig file and run:
  export KUBECONFIG=$(pwd)/$USER.kubeconfig
Then use kubectl commands as usual within this namespace.

If you have any questions, contact the cluster administrator.

Regards,
Cluster Admin
EOF
)

# Write email body to temp file
EMAIL_BODY_FILE=$(mktemp)
echo "$EMAIL_BODY" > "$EMAIL_BODY_FILE"

# Send email with attachment using mpack + msmtp
if ! mpack -s "Kubeconfig Access - $USER" -d "$EMAIL_BODY_FILE" "$KUBECONFIG_FILE" "$EMAIL"; then
  echo "❌ Failed to send email to $EMAIL"
  rm "$EMAIL_BODY_FILE"
  exit 1
fi

rm "$EMAIL_BODY_FILE"

echo "✅ Email sent to $EMAIL with kubeconfig."
