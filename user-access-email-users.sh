#!/bin/bash
set -euo pipefail

# Arguments
USER="$1"
NAMESPACE="$2"
EMAIL="$3"

# Constants
KIND_CONTAINER="multi-node-cluster-control-plane"
OUTPUT_DIR="./$USER"

# Check for required arguments
if [[ -z "$USER" || -z "$NAMESPACE" || -z "$EMAIL" ]]; then
  echo "Usage: $0 <username> <namespace> <email>"
  exit 1
fi

echo "👤 Creating Kubernetes user '$USER' with access restricted to namespace '$NAMESPACE'."
mkdir -p "$OUTPUT_DIR"

# Check if the Kind control plane container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${KIND_CONTAINER}$"; then
  echo "❌ Kind control plane container '$KIND_CONTAINER' is not running. Please start your kind cluster."
  exit 1
fi

echo "🔐 Generating private key and Certificate Signing Request (CSR) for user '$USER'..."
openssl genrsa -out "$OUTPUT_DIR/$USER.key" 2048
openssl req -new -key "$OUTPUT_DIR/$USER.key" -out "$OUTPUT_DIR/$USER.csr" -subj "/CN=$USER/O=${NAMESPACE}-user"

echo "📋 Copying CSR to Kind container '$KIND_CONTAINER' and signing certificate..."
docker cp "$OUTPUT_DIR/$USER.csr" "$KIND_CONTAINER:/var/tmp/$USER.csr"
docker exec "$KIND_CONTAINER" openssl x509 -req -in "/var/tmp/$USER.csr" \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca.key \
  -CAcreateserial \
  -out "/var/tmp/$USER.crt" -days 365

echo "📥 Retrieving signed certificate from Kind container..."
docker cp "$KIND_CONTAINER:/var/tmp/$USER.crt" "$OUTPUT_DIR/$USER.crt"

echo "🔧 Preparing kubeconfig file..."

# Extract cluster info from current context
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# Extract CA cert
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$OUTPUT_DIR/ca.crt"

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

echo "🔐 Creating RBAC Role and RoleBinding for user '$USER' in namespace '$NAMESPACE'..."
kubectl create role "$USER-role" \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=pods,services,deployments,secrets \
  --namespace="$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create rolebinding "$USER-binding" \
  --role="$USER-role" \
  --user="$USER" \
  --namespace="$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

chmod 600 "$KUBECONFIG_FILE"

echo "✉️ Preparing email to send kubeconfig to '$EMAIL'..."

EMAIL_BODY=$(cat <<EOF
Hi $USER,

Your Kubernetes access has been set up with the following details:

- Namespace: $NAMESPACE
- Cluster: $CLUSTER_NAME
- Server URL: $CLUSTER_SERVER

Attached to this email is your kubeconfig file, which contains the credentials and configuration required to access the Kubernetes cluster within your assigned namespace.

To use your kubeconfig:

1. Save the attached file securely on your local machine, for example:
   $(pwd)/$USER.kubeconfig

2. Set the KUBECONFIG environment variable to point to this file by running:

   export KUBECONFIG=$(pwd)/$USER.kubeconfig

3. You can now use kubectl to interact with resources in the '$NAMESPACE' namespace. For example:

   kubectl get pods
   kubectl get services
   kubectl create deployment myapp --image=nginx

Please keep your kubeconfig file private as it contains your authentication credentials.

If you encounter any issues or have questions, please contact the Cluster Administrator.

Best regards,
Cluster Administrator
EOF
)

# Write the email body to a temp file
EMAIL_BODY_FILE=$(mktemp)
echo "$EMAIL_BODY" > "$EMAIL_BODY_FILE"

# Send email with attachment using mpack
if mpack -s "Kubeconfig Access - $USER" -d "$EMAIL_BODY_FILE" "$KUBECONFIG_FILE" "$EMAIL"; then
  echo "✅ Email successfully sent to $EMAIL with kubeconfig attached."
else
  echo "❌ Failed to send email to $EMAIL."
  rm "$EMAIL_BODY_FILE"
  exit 1
fi

rm "$EMAIL_BODY_FILE"

echo "🎉 User creation and email notification complete!"
