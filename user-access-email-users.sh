#!/bin/bash
set -euo pipefail

#----------------------------#
# 🚀 Kubernetes User Creator #
#----------------------------#

# 🎯 Arguments
USER="$1"
NAMESPACE="$2"
EMAIL="$3"

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
if [[ -z "$USER" || -z "$NAMESPACE" || -z "$EMAIL" ]]; then
  echo -e "${RED}❗ Usage: $0 <username> <namespace> <email>${NC}"
  exit 1
fi

echo -e "${BLUE}👤 Creating user '${YELLOW}$USER${BLUE}' in namespace '${YELLOW}$NAMESPACE${BLUE}'...${NC}"

mkdir -p "$OUTPUT_DIR"

# 🔍 Check if Kind control plane is running
if ! docker ps --format '{{.Names}}' | grep -q "^${KIND_CONTAINER}$"; then
  echo -e "${RED}❌ Kind container '$KIND_CONTAINER' is not running!${NC}"
  exit 1
fi

# 🔐 Generate keys and certificate signing request
echo -e "${GREEN}🔑 Generating key and CSR for ${USER}...${NC}"
openssl genrsa -out "$OUTPUT_DIR/$USER.key" 2048
openssl req -new -key "$OUTPUT_DIR/$USER.key" -out "$OUTPUT_DIR/$USER.csr" -subj "/CN=$USER/O=${NAMESPACE}-user"

# 📜 Sign CSR using Kind's control plane CA
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

# 🛡️ Create RBAC resources
echo -e "${GREEN}🔐 Creating RBAC roles and bindings...${NC}"
kubectl create role "$USER-role" \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=pods,services,deployments,secrets \
  --namespace="$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create rolebinding "$USER-binding" \
  --role="$USER-role" \
  --user="$USER" \
  --namespace="$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

chmod 600 "$KUBECONFIG_FILE"

# 📨 Build HTML Email
EMAIL_BODY_FILE=$(mktemp)

cat <<EOF > "$EMAIL_BODY_FILE"
<html>
  <head>
    <style>
      body { font-family: 'Segoe UI', sans-serif; background-color: #f4f6f8; padding: 20px; color: #333; }
      h2 { color: #2c3e50; }
      strong { color: #2980b9; }
      ul { padding-left: 20px; }
      li { margin-bottom: 5px; }
      pre {
        background: #1e1e1e;
        color: #ecf0f1;
        padding: 12px;
        border-left: 5px solid #3498db;
        font-family: monospace;
        overflow-x: auto;
      }
      .footer {
        margin-top: 30px;
        font-size: 0.9em;
        color: #888;
        border-top: 1px solid #ccc;
        padding-top: 10px;
      }
    </style>
  </head>
  <body>
    <h2>🚀 Kubernetes Access for <span style="color:#27ae60;">$USER</span></h2>

    <p>Hello <strong>$USER</strong>,</p>

    <p>Your Kubernetes access has been successfully created with the following details:</p>

    <ul>
      <li><strong>Namespace:</strong> $NAMESPACE</li>
      <li><strong>Cluster Name:</strong> $CLUSTER_NAME</li>
      <li><strong>API Server URL:</strong> <span style="color:#8e44ad;">$CLUSTER_SERVER</span></li>
    </ul>

    <p>Attached is your <strong>kubeconfig</strong> file. You’ll use this to connect to the Kubernetes cluster.</p>

    <h3>🛠️ Instructions:</h3>
    <h4> Switch to assigned Namespace </h4>
    <pre>
1. Save the attached file:
   ~/$HOME/$USER.kubeconfig

2. Set the environment variable:
   export KUBECONFIG=~/$HOME/$USER.kubeconfig

3. Test your access:
   kubectl get pods
   kubectl get services
   kubectl create deployment myapp --image=nginx
    </pre>

    <div class="footer">
      🛡️ Please keep your credentials secure and do not share your kubeconfig file.<br>
      📧 If you have any questions, reach out to your Kubernetes administrator.<br><br>
      — <strong>Cluster Admin Team</strong>
    </div>
  </body>
</html>
EOF

# 📤 Send email with HTML and attachment
cat "$EMAIL_BODY_FILE" | mutt -e "set content_type=text/html" -s "🔐 Kubernetes Access Details for $USER" -a "$KUBECONFIG_FILE" -- "$EMAIL"

rm "$EMAIL_BODY_FILE"

echo -e "${GREEN}✅ Email with kubeconfig sent to ${EMAIL}${NC}"
