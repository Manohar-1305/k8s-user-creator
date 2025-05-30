#!/bin/bash
set -e

USER="$1"
NAMESPACE="dev"
KIND_CONTAINER="multi-node-cluster-control-plane"
OUTPUT_DIR="./$USER"

if [[ -z "$USER" ]]; then
  echo "Usage: $0 <username>"
  exit 1
fi

echo "👤 Creating user: $USER"
mkdir -p "$OUTPUT_DIR"

# Check if Kind control-plane container exists
if ! docker ps --format '{{.Names}}' | grep -q "^${KIND_CONTAINER}$"; then
  echo "❌ Kind control plane container '$KIND_CONTAINER' not found!"
  exit 1
fi

# Step 1: Generate user key and CSR locally
openssl genrsa -out "$OUTPUT_DIR/$USER.key" 2048
openssl req -new -key "$OUTPUT_DIR/$USER.key" -out "$OUTPUT_DIR/$USER.csr" -subj "/CN=$USER/O=$USER"

# Step 2: Copy CSR into Kind container
echo "🔐 Copying CSR to Kind container (/var/tmp)..."
docker cp "$OUTPUT_DIR/$USER.csr" "$KIND_CONTAINER:/var/tmp/$USER.csr"

# Step 3: Sign CSR inside Kind container
echo "🔐 Signing CSR inside Kind container..."
docker exec "$KIND_CONTAINER" openssl x509 -req -in "/var/tmp/$USER.csr" \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca.key \
  -CAcreateserial \
  -out "/var/tmp/$USER.crt" -days 365

# Step 4: Copy signed cert back
docker cp "$KIND_CONTAINER:/var/tmp/$USER.crt" "$OUTPUT_DIR/$USER.crt"

# Step 5: Extract cluster info
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$OUTPUT_DIR/ca.crt"

# Step 6: Create kubeconfig for the user
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

# Step 7: Create a Role in the dev namespace with limited permissions
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: $NAMESPACE
  name: ${USER}-dev-role
rules:
- apiGroups: ["", "apps", "batch"]   # core, apps and batch groups
  resources: ["pods", "deployments", "jobs", "services", "configmaps", "secrets"]
  verbs: ["get", "watch", "list", "create", "update", "patch", "delete"]
EOF

# Step 8: Bind the Role to the user
kubectl create rolebinding "${USER}-dev-binding" \
  --namespace="$NAMESPACE" \
  --role="${USER}-dev-role" \
  --user="$USER" \
  --dry-run=client -o yaml | kubectl apply -f -

chmod 600 "$KUBECONFIG_FILE"

echo "🎉 User '$USER' created with access limited to namespace '$NAMESPACE'"
echo "📄 Kubeconfig saved locally at: $KUBECONFIG_FILE"
chmod 777 "$KUBECONFIG_FILE"
