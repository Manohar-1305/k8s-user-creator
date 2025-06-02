#!/bin/bash
set -euo pipefail

#----------------------------#
# 🚀 Kubernetes User Creator #
#----------------------------#

# 🎯 Arguments
USER="$1"
EMAIL="$2"

# 🛠️ Constants
KIND_CONTAINER="multi-node-cluster-control-plane"
OUTPUT_DIR="./$USER"

# 🎨 Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 🧪 Input Validation
if [[ -z "$USER" || -z "$EMAIL" ]]; then
  echo -e "${RED}❗ Usage: $0 <username> <email>${NC}"
  exit 1
fi

echo -e "${BLUE}👤 Creating cluster-admin user '${YELLOW}$USER${BLUE}'...${NC}"

mkdir -p "$OUTPUT_DIR"

# 🔍 Check if Kind control plane is running
if ! docker ps --format '{{.Names}}' | grep -q "^${KIND_CONTAINER}$"; then
  echo -e "${RED}❌ Kind container '$KIND_CONTAINER' is not running!${NC}"
  exit 1
fi

# 🔐 Generate keys and CSR
echo -e "${GREEN}🔑 Generating key and CSR for ${USER}...${NC}"
openssl genrsa -out "$OUTPUT_DIR/$USER.key" 2048
openssl req -new -key "$OUTPUT_DIR/$USER.key" -out "$OUTPUT_DIR/$USER.csr" -subj "/CN=$USER/O=$USER"

# 📜 Sign CSR using Kind's CA
echo -e "${GREEN}📜 Signing CSR inside Kind container...${NC}"
docker cp "$OUTPUT_DIR/$USER.csr" "$KIND_CONTAINER:/var/tmp/$USER.csr"
docker exec "$KIND_CONTAINER" openssl x509 -req -in "/var/tmp/$USER.csr" \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca.key \
  -CAcreateserial \
  -out "/var/tmp/$USER.crt" -days 365
docker cp "$KIND_CONTAINER:/var/tmp/$USER.crt" "$OUTPUT_DIR/$USER.crt"

# ⚙️ Build kubeconfig
echo -e "${GREEN}⚙️  Building kubeconfig for ${USER}...${NC}"
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$OUTPUT_DIR/ca.crt"

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

# 🛡️ Create ClusterRoleBinding for cluster-admin access
echo -e "${GREEN}🔐 Creating cluster-admin ClusterRoleBinding...${NC}"
kubectl create clusterrolebinding "${USER}-cluster-admin-binding" \
  --clusterrole=cluster-admin \
  --user="$USER" \
  --dry-run=client -o yaml | kubectl apply -f -

chmod 600 "$KUBECONFIG_FILE"

# ✉️ Email the kubeconfig
EMAIL_BODY_FILE=$(mktemp --suffix=.html)
cat <<EOF > "$EMAIL_BODY_FILE"
<html>
  <body style="font-family: Arial, sans-serif; color: #333;">
    <h2 style="color:#2F5496;">Kubernetes Cluster Admin Access Details</h2>
    <p>Dear <strong>$USER</strong>,</p>
    <p>You have been granted <strong>cluster-admin</strong> access on the Kubernetes cluster <strong>$CLUSTER_NAME</strong>.</p>
    <h3>Important Details:</h3>
    <ul>
      <li><strong>API Server URL:</strong> <code>$CLUSTER_SERVER</code></li>
      <li><strong>User:</strong> $USER</li>
      <li><strong>Role:</strong> Cluster Admin (Full control over the cluster)</li>
    </ul>

    <h3>Using Your Kubeconfig</h3>
    <p>The attached <code>$USER.kubeconfig</code> file contains all the necessary credentials and cluster info to access Kubernetes cluster-wide.</p>
    <p>Please save the file securely on your local machine. To use it, run the following command in your terminal:</p>
    <pre style="background:#f4f4f4; padding:10px; border-radius:4px;">export KUBECONFIG=\$HOME/$USER.kubeconfig</pre>
    <p>After setting the environment variable, test your access by running:</p>
    <pre style="background:#f4f4f4; padding:10px; border-radius:4px;">kubectl get nodes</pre>

    <h3>Security Notice</h3>
    <p>
      <strong>Please keep your kubeconfig file confidential.</strong> It contains credentials that grant full access to the cluster.<br>
      Do not share this file via unsecured channels.<br>
      If you suspect your kubeconfig has been compromised, contact the cluster administrator immediately.
    </p>

    <p>If you have any questions or need further assistance, feel free to reach out.</p>
    <p>Best regards,<br>The Kubernetes Admin Team</p>
  </body>
</html>
EOF

echo -e "${GREEN}📧 Sending email to ${EMAIL} using mutt...${NC}"
echo "Please see the attached kubeconfig file." | mutt -e "set content_type=text/html" -s "Kubernetes Admin Access for $USER" -a "$KUBECONFIG_FILE" -- "$EMAIL" < "$EMAIL_BODY_FILE"

echo -e "${GREEN}✅ Cluster-admin user '$USER' created and kubeconfig sent to $EMAIL.${NC}"
