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

# Pinned, tested versions. Override with --chart-version / --rc-version or env vars.
# Chart 7.x changed the image UID from 999 to 65533 (see setup_chart).
# 8.9.0 is an LTS release (supported until Oct 31, 2027).
CHART_VERSION="${CHART_VERSION:-7.0.2}"
RC_VERSION="${RC_VERSION:-8.9.0}"

# Optional image mirror, e.g. quay.io/ryan_nix/rocket.chat. Avoids Docker Hub's
# anonymous pull rate limit, which the Developer Sandbox's shared egress hits often.
IMAGE_REPO="${IMAGE_REPO:-}"

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
    echo "  --rc-version <version>  - Rocket.Chat image tag (default: $RC_VERSION)"
    echo "  --chart-version <ver>   - Rocket.Chat Helm chart version (default: $CHART_VERSION)"
    echo "  --image-repo <repo>     - Pull Rocket.Chat from a mirror, e.g. quay.io/you/rocket.chat"
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

# True if version $1 >= version $2 (e.g. version_ge 8.9.0 8.5.0)
version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

installed_chart_version() {
    [ -f rocketchat/Chart.yaml ] && awk '/^version:/{print $2; exit}' rocketchat/Chart.yaml
}

setup_chart() {
    echo "📦 Adding RocketChat Helm repository..."
    helm repo add rocketchat https://rocketchat.github.io/helm-charts 2>/dev/null || true
    helm repo update

    echo "📥 Pulling RocketChat Helm chart $CHART_VERSION..."
    rm -rf rocketchat/
    helm pull rocketchat/rocketchat --version "$CHART_VERSION" --untar

    # Comment out ANY hardcoded runAsUser/fsGroup (999 in chart 6.x, 65533 in 7.x).
    # OpenShift's restricted SCC assigns a random UID from the namespace range instead.
    # deploy() also passes securityContext=null as a second safeguard.
    echo "🔧 Patching security contexts for OpenShift compatibility..."
    local expr='s/^([[:space:]]*)(runAsUser|fsGroup): [0-9]+/\1# \2: removed for OpenShift restricted SCC/'
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -E -i '' "$expr" rocketchat/values.yaml
    else
        sed -E -i "$expr" rocketchat/values.yaml
    fi

    if grep -qE '^[[:space:]]*(runAsUser|fsGroup): [0-9]+' rocketchat/values.yaml; then
        echo "❌ Hardcoded UID/GID still present in rocketchat/values.yaml"
        exit 1
    fi

    echo "✅ Chart $CHART_VERSION patched successfully!"
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
            --rc-version)   RC_VERSION="$2"; shift 2 ;;
            --chart-version) CHART_VERSION="$2"; shift 2 ;;
            --image-repo)   IMAGE_REPO="$2"; shift 2 ;;
            *)              shift ;;
        esac
    done

    # If admin-user is set, fill in defaults for pass and email
    if [ -n "$ADMIN_USER" ]; then
        if [ -z "$ADMIN_PASS" ]; then
            # Reuse the password from a previous run: Rocket.Chat only creates the
            # admin on first boot, so a new password here would never take effect.
            ADMIN_PASS=$(oc get "deployment/${RELEASE_NAME}-rocketchat" -n "$NAMESPACE" \
                -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ADMIN_PASS")].value}' 2>/dev/null || true)
            if [ -n "$ADMIN_PASS" ]; then
                echo "🔑 Reusing existing admin password from deployment"
            else
                ADMIN_PASS=$(generate_admin_password)
                echo "🔐 Generated admin password (meets Rocket.Chat complexity requirements)"
            fi
        fi
        ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
    fi

    echo "🚀 RocketChat on OpenShift - Deployment"
    echo "========================================"
    echo "Namespace:   $NAMESPACE"
    echo "Rocket.Chat: $RC_VERSION (chart $CHART_VERSION)"
    [ -n "$IMAGE_REPO" ] && echo "Image:       $IMAGE_REPO"
    echo ""

    # Resolve hostname (auto-detect or explicit)
    HOST=$(resolve_host "$HOST")
    echo "🌐 Host: $HOST"
    echo ""

    # Ensure the pinned chart version is present (re-pull if missing or stale)
    local CURRENT_CHART
    CURRENT_CHART=$(installed_chart_version || true)
    if [ "$CURRENT_CHART" != "$CHART_VERSION" ]; then
        if [ -n "$CURRENT_CHART" ]; then
            echo "📦 Local chart is $CURRENT_CHART, need $CHART_VERSION — refreshing..."
        else
            echo "📦 Chart not found, running setup..."
        fi
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
    HELM_ARGS+=(--set replicaCount=0 --set image.tag="$RC_VERSION")

    # Pull from a mirror if requested. The Deno init container below uses
    # .Values.image.repository too, so both containers follow the mirror.
    if [ -n "$IMAGE_REPO" ]; then
        echo "🪞 Using image mirror: $IMAGE_REPO:$RC_VERSION"
        HELM_ARGS+=(--set image.repository="$IMAGE_REPO")
    fi

    # -----------------------------------------------------------------------
    # Apps Engine fix for OpenShift's random UID — Rocket.Chat 8.5 to 8.8 ONLY.
    #
    # Those releases run apps under Deno with DENO_DIR defaulting to a
    # pre-built .deno-cache inside /app, owned by UID 65533 and not writable
    # by OpenShift's arbitrary UID, so marketplace apps fail to start. An init
    # container copies the cache into a writable emptyDir.
    #
    # 8.9.0 removed Deno: apps run on Node with read-only access to /app and
    # write only to /tmp (already an emptyDir), so no fix is needed. Helm
    # drops these overrides on upgrade because they are simply not passed.
    # -----------------------------------------------------------------------
    local HELM_FILES=()
    local OVERRIDES=""
    if version_ge "$RC_VERSION" 8.5.0 && ! version_ge "$RC_VERSION" 8.9.0; then
        echo "🦕 Rocket.Chat $RC_VERSION uses Deno — adding writable Apps Engine cache"
        # Trailing X's only: BSD/macOS mktemp does not randomize X's before a suffix
        OVERRIDES=$(mktemp "${TMPDIR:-/tmp}/rocketchat-openshift.XXXXXX")
        trap 'rm -f "$OVERRIDES"' EXIT
        HELM_FILES=(-f "$OVERRIDES")
        cat > "$OVERRIDES" <<'YAML'
extraEnv:
  - name: DENO_DIR
    value: /deno-cache
extraVolumes:
  - name: deno-cache
    emptyDir: {}
extraVolumeMounts:
  - name: deno-cache
    mountPath: /deno-cache
extraInitContainers:
  - name: deno-cache-copy
    image: '{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}'
    command:
      - sh
      - -c
      - |
        src=$(find /app/bundle/programs/server/npm/node_modules/@rocket.chat -maxdepth 3 -type d -name .deno-cache 2>/dev/null | head -1)
        [ -z "$src" ] && src=$(find /app -type d -name .deno-cache -prune 2>/dev/null | head -1)
        if [ -n "$src" ]; then
          cp -R "$src"/. /deno-cache/ && echo "Copied Deno cache from $src"
        else
          echo "WARNING: no .deno-cache found in image; Apps Engine apps may fail to start"
        fi
    volumeMounts:
      - name: deno-cache
        mountPath: /deno-cache
YAML
    fi

    helm upgrade --install "$RELEASE_NAME" ./rocketchat "${HELM_ARGS[@]}" "${HELM_FILES[@]}"
    [ -n "$OVERRIDES" ] && rm -f "$OVERRIDES"

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

    # Save credentials BEFORE the long rollout wait, so a slow or failed
    # image pull (e.g. Docker Hub rate limits) never loses the generated passwords.
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
    echo "💾 Credentials saved to rocketchat-credentials.txt"

    # Scale up — RC boots once with all env vars already in place
    echo "🚀 Scaling up RocketChat..."
    oc scale "deployment/${RELEASE_NAME}-rocketchat" --replicas=1 -n "$NAMESPACE"

    echo "⏳ Waiting for RocketChat to be ready..."
    if ! oc rollout status "deployment/${RELEASE_NAME}-rocketchat" -n "$NAMESPACE" --timeout=600s; then
        echo ""
        echo "⚠️  RocketChat did not become ready within 10 minutes."
        echo "   Credentials are already saved in rocketchat-credentials.txt."
        echo "   Check for image pull problems (Docker Hub rate limits are common on the Sandbox):"
        echo "     oc get events --sort-by=.lastTimestamp | grep -iE 'pull|image' | tail -5"
        echo "   Once the pod is running, re-running this script is safe: it reuses the saved"
        echo "   MongoDB password, and the admin account is only created on first boot."
        exit 1
    fi

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