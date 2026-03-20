#!/bin/bash
# deploy.sh - Deploy or cleanup RocketChat on OpenShift
#
# Usage:
#   ./deploy.sh                    - Deploy with auto-detected hostname
#   ./deploy.sh --host <hostname>  - Deploy with explicit hostname
#   ./deploy.sh --admin-user admin - Deploy and skip setup wizard
#   ./deploy.sh cleanup            - Remove entire deployment including data
#   ./deploy.sh wakeup             - Scale up hibernated pods

set -e

NAMESPACE="${NAMESPACE:-$(oc project -q 2>/dev/null || echo "rocketchat")}"
MONGODB_SECRET_NAME="mongodb-secret"
RELEASE_NAME="rocketchat"

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
    echo "  --host <hostname>       - RocketChat hostname (auto-detected if omitted)"
    echo "  --name <release>        - Helm release name (default: rocketchat)"
    echo "  --admin-user <username> - Admin username (skips setup wizard)"
    echo "  --admin-pass <password> - Admin password (generated if --admin-user set without this)"
    echo "  --admin-email <email>   - Admin email (default: admin@example.com)"
    echo ""
    echo "Examples:"
    echo "  $0                                                    # auto-detect, manual wizard"
    echo "  $0 --admin-user admin                                 # skip wizard, generate password"
    echo "  $0 --admin-user admin --admin-pass 'MyP@ss1234567!'   # skip wizard, explicit password"
    echo "  $0 --host rocketchat.apps.cluster.example.com         # explicit hostname"
    echo "  $0 wakeup"
    echo "  $0 cleanup"
}

generate_password() {
    openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 24
}

generate_admin_password() {
    # Rocket.Chat requires: 14+ chars, uppercase, lowercase, number, symbol, max 3 repeating
    local base
    base=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 12)
    echo "${base}@1Ax"
}

get_mongodb_password() {
    if oc get secret "$MONGODB_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        oc get secret "$MONGODB_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.MONGODB_INITDB_ROOT_PASSWORD}' | base64 -d
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# Auto-detect the OpenShift apps domain using multiple strategies
# ---------------------------------------------------------------------------
get_apps_domain() {
    local domain=""

    # Strategy 1: Cluster ingress config (works on full clusters)
    domain=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
    if [ -n "$domain" ]; then
        echo "$domain"
        return 0
    fi

    # Strategy 2: Infer from API server URL (api.<cluster> → apps.<cluster>)
    local api_url
    api_url=$(oc whoami --show-server 2>/dev/null || true)
    if [ -n "$api_url" ]; then
        # Strip scheme (http:// or https://), swap api. → apps., strip trailing port
        domain=$(echo "$api_url" | sed -e 's|^https*://||' -e 's|^api\.|apps.|' -e 's|:[0-9]*$||')
        if [ -n "$domain" ]; then
            echo "$domain"
            return 0
        fi
    fi

    # Strategy 3: Parse domain from an existing route in the namespace
    local existing_host
    existing_host=$(oc get routes -n "$NAMESPACE" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
    if [ -n "$existing_host" ]; then
        domain=$(echo "$existing_host" | sed 's/^[^.]*\.//')
        echo "$domain"
        return 0
    fi

    return 1
}

resolve_host() {
    local explicit_host="$1"

    # If the user passed --host, honour it
    if [ -n "$explicit_host" ]; then
        echo "$explicit_host"
        return 0
    fi

    # Otherwise auto-detect
    echo "🔍 Auto-detecting cluster apps domain..." >&2
    local apps_domain
    apps_domain=$(get_apps_domain) || true

    if [ -z "$apps_domain" ]; then
        echo "" >&2
        echo "❌ Could not auto-detect the apps domain." >&2
        echo "   Please specify a hostname explicitly:" >&2
        echo "   $0 --host rocketchat.apps.mycluster.example.com" >&2
        exit 1
    fi

    local host="${RELEASE_NAME}-${NAMESPACE}.${apps_domain}"
    echo "   Resolved hostname: $host" >&2
    echo "$host"
}

setup_chart() {
    echo "📦 Adding RocketChat Helm repository..."
    helm repo add rocketchat https://rocketchat.github.io/helm-charts 2>/dev/null || true
    helm repo update

    echo "📥 Pulling RocketChat Helm chart..."
    rm -rf rocketchat/
    helm pull rocketchat/rocketchat --untar

    # Patch hardcoded UID/GID that conflict with OpenShift restricted SCC
    echo "🔧 Patching security contexts for OpenShift compatibility..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' 's/runAsUser: 999/# runAsUser: 999  # Commented out for OpenShift/g' rocketchat/values.yaml
        sed -i '' 's/fsGroup: 999/# fsGroup: 999  # Commented out for OpenShift/g' rocketchat/values.yaml
    else
        sed -i 's/runAsUser: 999/# runAsUser: 999  # Commented out for OpenShift/g' rocketchat/values.yaml
        sed -i 's/fsGroup: 999/# fsGroup: 999  # Commented out for OpenShift/g' rocketchat/values.yaml
    fi

    echo "✅ Chart patched successfully!"
}

deploy_mongodb() {
    local password="$1"

    echo "🔑 Creating MongoDB secrets..."
    oc create secret generic "$MONGODB_SECRET_NAME" \
        --from-literal=MONGODB_INITDB_ROOT_USERNAME=admin \
        --from-literal=MONGODB_INITDB_ROOT_PASSWORD="$password" \
        --dry-run=client -o yaml | oc apply -n "$NAMESPACE" -f -
    oc label "secret/$MONGODB_SECRET_NAME" app.kubernetes.io/part-of=rocketchat -n "$NAMESPACE" --overwrite

    # Replica set auth requires a shared keyFile for internal member authentication.
    # Generate once and store as a secret; reuse on subsequent deploys.
    if ! oc get secret mongodb-keyfile -n "$NAMESPACE" &>/dev/null; then
        echo "🔐 Generating replica set keyFile..."
        openssl rand -base64 756 | tr -d '\n' > /tmp/mongodb-keyfile
        oc create secret generic mongodb-keyfile \
            --from-file=keyfile=/tmp/mongodb-keyfile \
            -n "$NAMESPACE"
        rm -f /tmp/mongodb-keyfile
    fi
    oc label secret/mongodb-keyfile app.kubernetes.io/part-of=rocketchat -n "$NAMESPACE" --overwrite

    echo "🍃 Deploying MongoDB..."
    cat <<EOF | oc apply -n "$NAMESPACE" -f -
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mongodb-data
  labels:
    app: mongodb
    app.kubernetes.io/name: mongodb
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: rocketchat
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongodb
  labels:
    app: mongodb
    app.kubernetes.io/name: mongodb
    app.kubernetes.io/component: database
    app.kubernetes.io/part-of: rocketchat
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
        app.kubernetes.io/part-of: rocketchat
    spec:
      initContainers:
        # OpenShift runs containers with a random UID and secret volume mounts
        # don't reliably enforce defaultMode. MongoDB requires keyFile perms <= 0400.
        # This init container copies the keyfile to an emptyDir with correct perms.
        - name: keyfile-fix
          image: mongodb/mongodb-community-server:8.2-ubi9
          command: ["sh", "-c", "cp /etc/mongodb-secret/keyfile /etc/mongodb/keyfile && chmod 0400 /etc/mongodb/keyfile"]
          volumeMounts:
            - name: mongodb-keyfile-secret
              mountPath: /etc/mongodb-secret
              readOnly: true
            - name: mongodb-keyfile
              mountPath: /etc/mongodb
      containers:
        - name: mongodb
          image: mongodb/mongodb-community-server:8.2-ubi9
          args: ["mongod", "--replSet", "rs0", "--bind_ip_all", "--keyFile", "/etc/mongodb/keyfile"]
          ports:
            - containerPort: 27017
              name: mongodb
          env:
            - name: MONGODB_INITDB_ROOT_USERNAME
              valueFrom:
                secretKeyRef:
                  name: $MONGODB_SECRET_NAME
                  key: MONGODB_INITDB_ROOT_USERNAME
            - name: MONGODB_INITDB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: $MONGODB_SECRET_NAME
                  key: MONGODB_INITDB_ROOT_PASSWORD
          volumeMounts:
            - name: mongodb-data
              mountPath: /data/db
            - name: mongodb-keyfile
              mountPath: /etc/mongodb
              readOnly: true
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "2Gi"
              cpu: "1000m"
          startupProbe:
            exec:
              command: ["mongosh", "--eval", "db.adminCommand('ping')"]
            failureThreshold: 30
            periodSeconds: 5
          livenessProbe:
            exec:
              command: ["mongosh", "--eval", "db.adminCommand('ping')"]
            periodSeconds: 10
            timeoutSeconds: 5
          readinessProbe:
            exec:
              command: ["mongosh", "--eval", "db.adminCommand('ping')"]
            periodSeconds: 10
            timeoutSeconds: 5
      volumes:
        - name: mongodb-data
          persistentVolumeClaim:
            claimName: mongodb-data
        - name: mongodb-keyfile-secret
          secret:
            secretName: mongodb-keyfile
        - name: mongodb-keyfile
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb
  labels:
    app: mongodb
    app.kubernetes.io/name: mongodb
    app.kubernetes.io/part-of: rocketchat
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
    oc rollout status deployment/mongodb -n "$NAMESPACE" --timeout=180s

    # Initiate single-node replica set (required for oplog support).
    # The member host MUST use the service FQDN, not localhost, so that the
    # replica set driver in Rocket.Chat can route connections correctly.
    echo "🔧 Initializing MongoDB replica set..."
    local MONGO_HOST="mongodb.${NAMESPACE}.svc.cluster.local:27017"
    oc exec deployment/mongodb -n "$NAMESPACE" -- mongosh \
        "mongodb://admin:${password}@localhost:27017/admin" \
        --quiet --eval "
        try {
            rs.initiate({ _id: 'rs0', members: [{ _id: 0, host: '${MONGO_HOST}' }] });
            print('Replica set initiated');
        } catch (e) {
            if (e.codeName === 'AlreadyInitialized') {
                print('Replica set already initialized');
            } else {
                throw e;
            }
        }"
}

deploy() {
    local HOST=""
    local ADMIN_USER=""
    local ADMIN_PASS=""
    local ADMIN_EMAIL=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --host)         HOST="$2"; shift 2 ;;
            --name)         RELEASE_NAME="$2"; shift 2 ;;
            --admin-user)   ADMIN_USER="$2"; shift 2 ;;
            --admin-pass)   ADMIN_PASS="$2"; shift 2 ;;
            --admin-email)  ADMIN_EMAIL="$2"; shift 2 ;;
            *)              shift ;;
        esac
    done

    # If admin-user is set, fill in defaults for pass and email
    if [ -n "$ADMIN_USER" ]; then
        if [ -z "$ADMIN_PASS" ]; then
            ADMIN_PASS=$(generate_admin_password)
            echo "🔐 Generated admin password (meets Rocket.Chat complexity requirements)"
        fi
        ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
    fi

    echo "🚀 RocketChat on OpenShift - Deployment"
    echo "========================================"
    echo "Namespace: $NAMESPACE"
    echo ""

    # Resolve hostname (auto-detect or explicit)
    HOST=$(resolve_host "$HOST")
    echo "🌐 Host: $HOST"
    echo ""

    # Ensure chart is available
    if [ ! -d "rocketchat" ]; then
        echo "📦 Chart not found, running setup..."
        setup_chart
        echo ""
    fi

    # Resolve MongoDB password (reuse existing or generate)
    local MONGODB_PASSWORD
    MONGODB_PASSWORD=$(get_mongodb_password)
    if [ -n "$MONGODB_PASSWORD" ]; then
        echo "🔑 Reusing existing MongoDB password from secret..."
    else
        echo "🔐 Generating new MongoDB password..."
        MONGODB_PASSWORD=$(generate_password)
    fi

    # Deploy MongoDB
    deploy_mongodb "$MONGODB_PASSWORD"

    # Build connection strings
    local MONGO_URL="mongodb://admin:${MONGODB_PASSWORD}@mongodb.${NAMESPACE}.svc.cluster.local:27017/rocketchat?authSource=admin&replicaSet=rs0"
    local MONGO_OPLOG_URL="mongodb://admin:${MONGODB_PASSWORD}@mongodb.${NAMESPACE}.svc.cluster.local:27017/local?authSource=admin&replicaSet=rs0"

    # -----------------------------------------------------------------------
    # Deploy RocketChat with relaxed probes to prevent restarts during
    # first-run setup (admin registration, index creation, migrations).
    #
    # Always deploys with replicas=0 so env vars (MONGO_OPLOG_URL, admin
    # credentials) can be injected before RC boots. Prevents double-rollouts.
    # -----------------------------------------------------------------------
    echo "🚀 Deploying RocketChat..."
    local HELM_ARGS=(
        --namespace "$NAMESPACE"
        --set host="$HOST"
        --set ingress.enabled=false
        --set mongodb.enabled=false
        --set microservices.enabled=false
        --set nats.enabled=false
        --set externalMongodbUrl="$MONGO_URL"
        --set externalMongodbOplogUrl="$MONGO_OPLOG_URL"
        --set podSecurityContext=null
        --set containerSecurityContext=null
        --set securityContext=null
        --set serviceAccount.create=true
        --set livenessProbe.enabled=true
        --set livenessProbe.httpGet.path="/health"
        --set livenessProbe.httpGet.port=3000
        --set livenessProbe.initialDelaySeconds=120
        --set livenessProbe.periodSeconds=15
        --set livenessProbe.timeoutSeconds=10
        --set livenessProbe.failureThreshold=6
        --set readinessProbe.enabled=true
        --set readinessProbe.httpGet.path="/health"
        --set readinessProbe.httpGet.port=3000
        --set readinessProbe.initialDelaySeconds=30
        --set readinessProbe.periodSeconds=10
        --set readinessProbe.timeoutSeconds=5
        --set readinessProbe.failureThreshold=6
        --set resources.requests.memory="512Mi"
        --set resources.requests.cpu="250m"
        --set resources.limits.memory="2Gi"
        --set resources.limits.cpu="1000m"
    )

    # Always start with replicas=0 so we can inject env vars (MONGO_OPLOG_URL
    # at minimum) before RC boots. This prevents a double-rollout.
    HELM_ARGS+=(--set replicaCount=0)

    helm upgrade --install "$RELEASE_NAME" ./rocketchat "${HELM_ARGS[@]}"

    # Group RC and MongoDB together in the OpenShift topology view.
    # Must label ALL resources — deployment, service, route, PVC — for
    # OpenShift to render them in the same visual group.
    echo "🏷️  Applying topology labels..."
    oc label "deployment/${RELEASE_NAME}-rocketchat" app.kubernetes.io/part-of=rocketchat -n "$NAMESPACE" --overwrite
    oc label "svc/${RELEASE_NAME}-rocketchat" app.kubernetes.io/part-of=rocketchat -n "$NAMESPACE" --overwrite 2>/dev/null || true
    oc annotate "deployment/${RELEASE_NAME}-rocketchat" app.openshift.io/connects-to='["mongodb"]' -n "$NAMESPACE" --overwrite

    # Create the Route explicitly — more reliable than Ingress-to-Route conversion
    echo "🌐 Creating OpenShift Route..."
    local SVC_NAME
    SVC_NAME=$(oc get svc -n "$NAMESPACE" -l "app.kubernetes.io/instance=$RELEASE_NAME,app.kubernetes.io/name=rocketchat" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "${RELEASE_NAME}-rocketchat")

    if oc get route rocketchat -n "$NAMESPACE" &>/dev/null; then
        echo "   Route already exists, updating hostname..."
        oc patch route rocketchat -n "$NAMESPACE" --type merge -p "{\"spec\":{\"host\":\"$HOST\"}}"
    else
        oc create route edge rocketchat \
            --service="$SVC_NAME" \
            --port=http \
            --hostname="$HOST" \
            -n "$NAMESPACE"
    fi
    oc label route/rocketchat app.kubernetes.io/part-of=rocketchat -n "$NAMESPACE" --overwrite 2>/dev/null || true

    # -----------------------------------------------------------------------
    # Inject env vars while replicas=0 (no rollout triggered), then scale up.
    # MONGO_OPLOG_URL must always be injected because the Helm chart's secret
    # only stores mongo-uri, not the oplog URI.
    #
    # When --admin-user is set, admin credentials and the wizard-skip setting
    # are also injected, followed by a post-boot MongoDB update.
    # -----------------------------------------------------------------------
    echo "🔧 Configuring environment..."
    if [ -n "$ADMIN_USER" ]; then
        echo "👤 Admin user: $ADMIN_USER (setup wizard will be skipped)"
        oc set env "deployment/${RELEASE_NAME}-rocketchat" -n "$NAMESPACE" \
            MONGO_OPLOG_URL="$MONGO_OPLOG_URL" \
            ADMIN_USERNAME="$ADMIN_USER" \
            ADMIN_PASS="$ADMIN_PASS" \
            ADMIN_EMAIL="$ADMIN_EMAIL" \
            OVERWRITE_SETTING_Show_Setup_Wizard=completed
    else
        oc set env "deployment/${RELEASE_NAME}-rocketchat" -n "$NAMESPACE" \
            MONGO_OPLOG_URL="$MONGO_OPLOG_URL"
    fi

    # Scale up — RC boots once with all env vars already in place
    echo "🚀 Scaling up RocketChat..."
    oc scale "deployment/${RELEASE_NAME}-rocketchat" --replicas=1 -n "$NAMESPACE"

    echo "⏳ Waiting for RocketChat to be ready..."
    oc rollout status "deployment/${RELEASE_NAME}-rocketchat" -n "$NAMESPACE" --timeout=300s

    # If admin was configured, flip the wizard setting in MongoDB.
    # RC picks this up immediately via change streams.
    if [ -n "$ADMIN_USER" ]; then
        echo "🔧 Completing setup wizard via MongoDB..."
        oc exec deployment/mongodb -n "$NAMESPACE" -- mongosh \
            "mongodb://admin:${MONGODB_PASSWORD}@localhost:27017/rocketchat?authSource=admin" \
            --quiet --eval '
            db.rocketchat_settings.updateOne(
                { _id: "Show_Setup_Wizard" },
                { $set: { value: "completed" } }
            )'
        echo "✅ Setup wizard skipped — admin user configured"
    fi

    # Save credentials
    cat > rocketchat-credentials.txt <<CREDS
RocketChat Deployment Credentials
==================================
Namespace:  $NAMESPACE
URL:        https://$HOST

MongoDB
  Username: admin
  Password: $MONGODB_PASSWORD
  Service:  mongodb.$NAMESPACE.svc.cluster.local:27017
CREDS

    if [ -n "$ADMIN_USER" ]; then
        cat >> rocketchat-credentials.txt <<CREDS

RocketChat Admin
  Username: $ADMIN_USER
  Password: $ADMIN_PASS
  Email:    $ADMIN_EMAIL
CREDS
    fi

    chmod 600 rocketchat-credentials.txt

    echo ""
    echo "✅ Deployment complete!"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 Deployment Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Namespace:  $NAMESPACE"
    echo "   Host:       https://$HOST"
    if [ -n "$ADMIN_USER" ]; then
        echo "   Admin:      $ADMIN_USER ($ADMIN_EMAIL)"
        echo "   Setup:      Wizard skipped — admin pre-configured"
    fi
    echo "   Credentials saved to: rocketchat-credentials.txt"
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
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || echo "   (Helm release not found or already removed)"

    echo "🗑️  Removing OpenShift Route..."
    oc delete route rocketchat -n "$NAMESPACE" 2>/dev/null || true

    echo "🗑️  Removing MongoDB deployment..."
    oc delete deployment mongodb -n "$NAMESPACE" 2>/dev/null || true
    oc delete service mongodb -n "$NAMESPACE" 2>/dev/null || true
    oc delete secret "$MONGODB_SECRET_NAME" -n "$NAMESPACE" 2>/dev/null || true
    oc delete secret mongodb-keyfile -n "$NAMESPACE" 2>/dev/null || true

    echo "🗑️  Removing PVCs..."
    oc delete pvc mongodb-data -n "$NAMESPACE" 2>/dev/null || true
    oc delete pvc -l "app.kubernetes.io/instance=$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || true

    echo "🗑️  Removing local chart directory..."
    rm -rf rocketchat/
    rm -f rocketchat-credentials.txt

    echo ""
    echo "✅ Cleanup complete!"
}

wakeup() {
    echo "☀️  RocketChat on OpenShift - Wake Up"
    echo "======================================"
    echo "Namespace: $NAMESPACE"
    echo ""

    echo "🍃 Scaling up MongoDB first..."
    oc scale deployment mongodb --replicas=1 -n "$NAMESPACE"
    oc rollout status deployment/mongodb -n "$NAMESPACE" --timeout=180s

    echo "🚀 Scaling up RocketChat..."
    oc scale deployment --all --replicas=1 -n "$NAMESPACE"

    echo ""
    echo "✅ All pods scaling up!"
    echo "   Watch progress: oc get pods -w"
}

# Main
case "${1:-}" in
    cleanup|--cleanup)   cleanup ;;
    wakeup|--wakeup)     wakeup ;;
    -h|--help|help)      show_help; exit 0 ;;
    *)                   deploy "$@" ;;
esac