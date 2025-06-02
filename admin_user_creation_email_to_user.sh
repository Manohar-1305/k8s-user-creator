#!/bin/bash
set -e

USER="$1"
EMAIL="$2"
OUTPUT_DIR="./$USER"
KIND_CONTAINER="multi-node-cluster-control-plane"

if [[ -z "$USER" || -z "$EMAIL" ]]; then
  echo "Usage: $0 <username> <email>"
  exit 1
fi

echo "👤 Creating user: $USER"
mkdir -p "$OUTPUT_DIR"

# Check if Kind control-plane container exists
if ! docker ps --format '{{.Names}}' | grep -q "^${KIND_CONTAINER}$"; then
  echo "❌ Kind control plane container '$KIND_CONTAINER' not found!"
  echo "Available containers:"
  docker ps --format '{{.Names}}'
  exit 1
fi

# Step 1: Generate private key and CSR locally
openssl genrsa -out "$OUTPUT_DIR/$USER.key" 2048
openssl req -new -key "$OUTPUT_DIR/$USER.key" -out "$OUTPUT_DIR/$USER.csr" -subj "/CN=$USER/O=system:masters"

# Step 2: Copy CSR into Kind container
echo "🔐 Copying CSR to Kind container (/var/tmp)..."
docker cp "$OUTPUT_DIR/$USER.csr" "$KIND_CONTAINER:/var/tmp/$USER.csr"

# Step 3: Sign the CSR inside Kind container with cluster CA
echo "🔐 Signing CSR inside Kind container..."
docker exec "$KIND_CONTAINER" openssl x509 -req -in "/var/tmp/$USER.csr" \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca.key \
  -CAcreateserial \
  -out "/var/tmp/$USER.crt" -days 365

# Step 4: Copy signed cert back to local filesystem
docker cp "$KIND_CONTAINER:/var/tmp/$USER.crt" "$OUTPUT_DIR/$USER.crt"

# Step 5: Extract cluster info for kubeconfig creation
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$OUTPUT_DIR/ca.crt"

# Step 6: Generate kubeconfig locally
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
  --user="$USER"

kubectl config --kubeconfig="$KUBECONFIG_FILE" use-context "$USER-context"

# Step 7: Create clusterrolebinding for full access
kubectl create clusterrolebinding "$USER-cluster-admin-binding" \
  --clusterrole=cluster-admin \
  --user="$USER" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "🎉 User '$USER' created with full cluster-admin access!"
echo "📄 Kubeconfig saved locally at: $KUBECONFIG_FILE"
echo "➡️  You can now copy this kubeconfig file to your laptop manually."

# Set kubeconfig file permission to read/write only for the owner
chmod 600 "$KUBECONFIG_FILE"

# Email body
EMAIL_BODY="Hi $USER,

Your kubeconfig file granting full cluster-admin access to the Kubernetes cluster has been generated and is attached to this email.

To use it, save the attached kubeconfig file and run:
  export KUBECONFIG=\$(pwd)/$USER.kubeconfig

Then you can interact with your Kubernetes cluster with full administrative privileges.

If you have any questions or need assistance, feel free to reach out.

Regards,
Cluster Admin"

# Write email body to a temporary file
EMAIL_BODY_FILE=$(mktemp)
echo "$EMAIL_BODY" > "$EMAIL_BODY_FILE"

# Send email with kubeconfig attached using mpack
if command -v mpack &> /dev/null; then
  if mpack -s "Kubeconfig Access for user $USER" -d "$EMAIL_BODY_FILE" "$KUBECONFIG_FILE" "$EMAIL"; then
    echo "✅ Email sent successfully to $EMAIL."
  else
    echo "❌ Failed to send email to $EMAIL."
  fi
else
  echo "⚠️ mpack not found. Skipping email sending."
fi

# Cleanup
rm "$EMAIL_BODY_FILE"
