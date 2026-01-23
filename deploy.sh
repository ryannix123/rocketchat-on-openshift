#!/bin/bash
# deploy.sh - Deploy or cleanup RocketChat on OpenShift
#
# Usage:
#   ./deploy.sh --host <hostname>  - Deploy MongoDB and RocketChat
#   ./deploy.sh cleanup            - Remove entire deployment including data
#   ./deploy.sh wakeup             - Scale up hibernated pods

set -e

NAMESPACE="${NAMESPACE:-$(oc project -q 2>/dev/null || echo "rocketchat")}"
MONGODB_SECRET_NAME="mongodb-secret"

show_help() {
    echo "🚀 RocketChat on OpenShift - Deployment Script"
    echo "==============================================="
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Commands:"
    echo "  (default)   - Deploy MongoDB and RocketChat"
    echo "  cleanup     - Remove entire deployment including data"
    echo "  wakeup      - Scale up pods after Developer Sandbox hibernation"
    echo ""
    echo "Options:"
    echo "  --host <hostname>  - RocketChat hostname (required for first deploy)"
    echo ""
    echo "Examples:"
    echo "  $0 --host rocketchat.apps.cluster.example.com"
    echo "  $0 wakeup"
    echo "  $0 cleanup"
}

generate_password() {
    # Generate a secure random password (alphanumeric, 24 chars)
    openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 24
}

get_mongodb_password() {
    # Try to get existing password from secret
    if oc get secret "$MONGODB_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        oc get secret "$MONGODB_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d
    else
        echo ""
    fi
}

setup_chart() {
    echo "🚀 RocketChat on OpenShift - Chart Setup"
    echo "========================================="
    echo ""

    # Add Helm repo
    echo "📦 Adding RocketChat Helm repository..."
    helm repo add rocketchat https://rocketchat.github.io/helm-charts 2>/dev/null || true
    helm repo update

    # Pull the chart
    echo "📥 Pulling RocketChat Helm chart..."
    rm -rf rocketchat/  # Remove existing chart if present
    helm pull rocketchat/rocketchat --untar

    # Patch security contexts
    echo "🔧 Patching security contexts for OpenShift compatibility..."

    # Detect OS for sed compatibility
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' 's/runAsUser: 999/# runAsUser: 999  # Commented out for OpenShift/g' rocketchat/values.yaml
        sed -i '' 's/fsGroup: 999/# fsGroup: 999  # Commented out for OpenShift/g' rocketchat/values.yaml
    else
        # Linux
        sed -i 's/runAsUser: 999/# runAsUser: 999  # Commented out for OpenShift/g' rocketchat/values.yaml
        sed -i 's/fsGroup: 999/# fsGroup: 999  # Commented out for OpenShift/g' rocketchat/values.yaml
    fi

    echo ""
    echo "✅ Chart patched successfully!"
}

deploy() {
    local HOST=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --host)
                HOST="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    echo "🚀 RocketChat on OpenShift - Deployment"
    echo "========================================"
    echo "Namespace: $NAMESPACE"
    echo ""

    # Check if chart exists, run setup if not
    if [ ! -d "rocketchat" ]; then
        echo "📦 Chart not found, running setup first..."
        setup_chart
        echo ""
    fi

    # Check for existing deployment
    local EXISTING_PASSWORD=$(get_mongodb_password)
    local MONGODB_PASSWORD=""
    
    if [ -n "$EXISTING_PASSWORD" ]; then
        echo "🔑 Using existing MongoDB password from secret..."
        MONGODB_PASSWORD="$EXISTING_PASSWORD"
    else
        echo "🔐 Generating new MongoDB password..."
        MONGODB_PASSWORD=$(generate_password)
    fi

    # Get or require host
    if [ -z "$HOST" ]; then
        # Try to get from existing values.yml
        if [ -f "values.yml" ]; then
            HOST=$(grep "^host:" values.yml 2>/dev/null | awk '{print $2}' | tr -d '"' | tr -d "'")
        fi
        
        if [ -z "$HOST" ] || [[ "$HOST" == *"<your"* ]]; then
            echo ""
            echo "❌ Error: Hostname is required for deployment."
            echo ""
            echo "Usage: $0 --host <your-rocketchat-hostname>"
            echo ""
            echo "Example:"
            echo "  $0 --host rocketchat.apps.rm3.7wse.p1.openshiftapps.com"
            echo ""
            echo "To find your OpenShift apps domain:"
            echo "  oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'"
            exit 1
        fi
    fi

    echo "🌐 Host: $HOST"
    echo ""

    # Create/update MongoDB secret
    echo "🔑 Creating MongoDB secret..."
    oc create secret generic "$MONGODB_SECRET_NAME" \
        --from-literal=MONGO_INITDB_ROOT_USERNAME=admin \
        --from-literal=MONGO_INITDB_ROOT_PASSWORD="$MONGODB_PASSWORD" \
        --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f -

    # Deploy MongoDB (without the secret, since we created it separately)
    echo "🍃 Deploying MongoDB..."
    cat <<EOF | oc apply -n "$NAMESPACE" -f -
---
# MongoDB PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mongodb-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
# MongoDB Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongodb
  labels:
    app: mongodb
    app.kubernetes.io/name: mongodb
    app.kubernetes.io/component: database
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mongodb
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: mongodb
        app.kubernetes.io/name: mongodb
    spec:
      containers:
        - name: mongodb
          image: mongodb/mongodb-community-server:8.2-ubi9
          ports:
            - containerPort: 27017
              name: mongodb
          env:
            - name: MONGO_INITDB_ROOT_USERNAME
              valueFrom:
                secretKeyRef:
                  name: $MONGODB_SECRET_NAME
                  key: MONGO_INITDB_ROOT_USERNAME
            - name: MONGO_INITDB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: $MONGODB_SECRET_NAME
                  key: MONGO_INITDB_ROOT_PASSWORD
          volumeMounts:
            - name: mongodb-data
              mountPath: /data/db
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "2Gi"
              cpu: "1000m"
          livenessProbe:
            exec:
              command:
                - mongosh
                - --eval
                - "db.adminCommand('ping')"
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
          readinessProbe:
            exec:
              command:
                - mongosh
                - --eval
                - "db.adminCommand('ping')"
            initialDelaySeconds: 5
            periodSeconds: 10
            timeoutSeconds: 5
      volumes:
        - name: mongodb-data
          persistentVolumeClaim:
            claimName: mongodb-data
---
# MongoDB Service
apiVersion: v1
kind: Service
metadata:
  name: mongodb
  labels:
    app: mongodb
    app.kubernetes.io/name: mongodb
spec:
  ports:
    - port: 27017
      targetPort: 27017
      name: mongodb
  selector:
    app: mongodb
  type: ClusterIP
EOF

    echo "⏳ Waiting for MongoDB to be ready..."
    oc rollout status deployment/mongodb -n "$NAMESPACE" --timeout=120s

    # Build MongoDB connection strings
    local MONGO_URL="mongodb://admin:${MONGODB_PASSWORD}@mongodb.${NAMESPACE}.svc.cluster.local:27017/rocketchat?authSource=admin"
    local MONGO_OPLOG_URL="mongodb://admin:${MONGODB_PASSWORD}@mongodb.${NAMESPACE}.svc.cluster.local:27017/local?authSource=admin"

    # Deploy RocketChat
    echo "🚀 Deploying RocketChat..."
    helm upgrade --install rocketchat ./rocketchat \
        --namespace "$NAMESPACE" \
        --set host="$HOST" \
        --set ingress.enabled=true \
        --set ingress.annotations."route\.openshift\.io/termination"=edge \
        --set mongodb.enabled=false \
        --set externalMongodbUrl="$MONGO_URL" \
        --set externalMongodbOplogUrl="$MONGO_OPLOG_URL" \
        --set podSecurityContext=null \
        --set containerSecurityContext=null \
        --set securityContext=null \
        --set serviceAccount.create=true

    echo ""
    echo "✅ Deployment initiated!"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 Deployment Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Namespace:  $NAMESPACE"
    echo "   Host:       https://$HOST"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "⏳ Wait for pods to be ready:"
    echo "   oc get pods -w"
    echo ""
    echo "🌐 Then open: https://$HOST"
    echo ""
}

cleanup() {
    echo "🧹 RocketChat on OpenShift - Cleanup"
    echo "====================================="
    echo "Namespace: $NAMESPACE"
    echo ""
    echo "⚠️  This will delete the entire deployment including all data!"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi

    echo "🗑️  Removing RocketChat Helm release..."
    helm uninstall rocketchat -n "$NAMESPACE" 2>/dev/null || echo "   (Helm release not found or already removed)"

    echo "🗑️  Removing MongoDB deployment..."
    oc delete deployment mongodb -n "$NAMESPACE" 2>/dev/null || true
    oc delete service mongodb -n "$NAMESPACE" 2>/dev/null || true
    oc delete secret "$MONGODB_SECRET_NAME" -n "$NAMESPACE" 2>/dev/null || true

    echo "🗑️  Removing PVCs..."
    oc delete pvc mongodb-data -n "$NAMESPACE" 2>/dev/null || true
    oc delete pvc -l app.kubernetes.io/instance=rocketchat -n "$NAMESPACE" 2>/dev/null || true

    echo "🗑️  Removing local chart directory..."
    rm -rf rocketchat/

    echo ""
    echo "✅ Cleanup complete!"
}

wakeup() {
    echo "☀️  RocketChat on OpenShift - Wake Up"
    echo "======================================"
    echo "Namespace: $NAMESPACE"
    echo ""

    echo "🍃 Scaling up MongoDB..."
    oc scale deployment mongodb --replicas=1 -n "$NAMESPACE"
    oc rollout status deployment/mongodb -n "$NAMESPACE" --timeout=120s

    echo "📊 Scaling up StatefulSets (NATS)..."
    oc scale statefulset --all --replicas=1 -n "$NAMESPACE"

    echo "🚀 Scaling up Deployments..."
    oc scale deployment --all --replicas=1 -n "$NAMESPACE"

    echo ""
    echo "✅ All pods scaling up!"
    echo ""
    echo "⏳ Wait a moment for RocketChat to reconnect to MongoDB."
    echo "   Watch progress: oc get pods -w"
}

# Main
case "${1:-}" in
    cleanup)
        cleanup
        ;;
    wakeup)
        wakeup
        ;;
    -h|--help|help)
        show_help
        exit 0
        ;;
    *)
        deploy "$@"
        ;;
esac
