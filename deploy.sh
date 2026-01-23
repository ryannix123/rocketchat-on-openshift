#!/bin/bash
# deploy.sh - Deploy or cleanup RocketChat on OpenShift
#
# Usage:
#   ./deploy.sh setup      - Pull and patch the Helm chart
#   ./deploy.sh deploy     - Deploy MongoDB and RocketChat
#   ./deploy.sh cleanup    - Remove RocketChat deployment (keeps PVCs)
#   ./deploy.sh cleanup-all - Remove everything including PVCs
#   ./deploy.sh wakeup     - Scale up hibernated pods

set -e

NAMESPACE="${NAMESPACE:-$(oc project -q 2>/dev/null || echo "rocketchat")}"

show_help() {
    echo "🚀 RocketChat on OpenShift - Deployment Script"
    echo "==============================================="
    echo ""
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  setup       - Pull and patch the RocketChat Helm chart"
    echo "  deploy      - Deploy MongoDB and RocketChat (runs setup first if needed)"
    echo "  cleanup     - Remove RocketChat deployment (keeps PVCs for data)"
    echo "  cleanup-all - Remove everything including persistent data"
    echo "  wakeup      - Scale up pods after Developer Sandbox hibernation"
    echo ""
    echo "Environment variables:"
    echo "  NAMESPACE   - OpenShift namespace (default: current project or 'rocketchat')"
    echo ""
    echo "Examples:"
    echo "  $0 setup"
    echo "  $0 deploy"
    echo "  NAMESPACE=my-project $0 deploy"
    echo "  $0 wakeup"
    echo "  $0 cleanup"
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

    # Check if values.yml exists
    if [ ! -f "values.yml" ]; then
        echo "❌ Error: values.yml not found!"
        echo "   Please create values.yml with your configuration."
        echo "   See README.md for details."
        exit 1
    fi

    # Deploy MongoDB
    echo "🍃 Deploying MongoDB..."
    oc apply -f mongodb-standalone.yaml -n "$NAMESPACE"

    echo "⏳ Waiting for MongoDB to be ready..."
    oc rollout status deployment/mongodb -n "$NAMESPACE" --timeout=120s

    # Deploy RocketChat
    echo "🚀 Deploying RocketChat..."
    helm install rocketchat ./rocketchat -f values.yml -n "$NAMESPACE"

    echo ""
    echo "✅ Deployment initiated!"
    echo ""
    echo "📋 Next steps:"
    echo "   1. Watch pods come up: oc get pods -w -n $NAMESPACE"
    echo "   2. Get the route: oc get route -n $NAMESPACE"
    echo "   3. Complete RocketChat setup wizard in your browser"
    echo ""
    echo "🔍 Troubleshooting:"
    echo "   View logs: oc logs deployment/rocketchat-rocketchat -n $NAMESPACE"
}

cleanup() {
    echo "🧹 RocketChat on OpenShift - Cleanup"
    echo "====================================="
    echo "Namespace: $NAMESPACE"
    echo ""

    echo "🗑️  Removing RocketChat Helm release..."
    helm uninstall rocketchat -n "$NAMESPACE" 2>/dev/null || echo "   (Helm release not found or already removed)"

    echo "🗑️  Removing MongoDB deployment..."
    oc delete -f mongodb-standalone.yaml -n "$NAMESPACE" 2>/dev/null || echo "   (MongoDB resources not found or already removed)"

    echo "🗑️  Removing local chart directory..."
    rm -rf rocketchat/

    echo ""
    echo "✅ Cleanup complete!"
    echo ""
    echo "ℹ️  PVCs were preserved. To delete all data, run:"
    echo "   $0 cleanup-all"
    echo ""
    echo "   Or manually delete PVCs:"
    echo "   oc delete pvc -l app=mongodb -n $NAMESPACE"
    echo "   oc delete pvc -l app.kubernetes.io/instance=rocketchat -n $NAMESPACE"
}

cleanup_all() {
    echo "🧹 RocketChat on OpenShift - Full Cleanup"
    echo "=========================================="
    echo "Namespace: $NAMESPACE"
    echo ""
    echo "⚠️  WARNING: This will delete all data including PVCs!"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 0
    fi

    cleanup

    echo "🗑️  Removing PVCs..."
    oc delete pvc mongodb-data -n "$NAMESPACE" 2>/dev/null || true
    oc delete pvc -l app.kubernetes.io/instance=rocketchat -n "$NAMESPACE" 2>/dev/null || true

    echo ""
    echo "✅ Full cleanup complete! All data has been removed."
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
    echo "   Watch progress: oc get pods -w -n $NAMESPACE"
}

# Main
case "${1:-}" in
    setup)
        setup_chart
        echo ""
        echo "📋 Next steps:"
        echo "   1. Update values.yml with your domain and MongoDB password"
        echo "   2. Run: $0 deploy"
        ;;
    deploy)
        deploy
        ;;
    cleanup)
        cleanup
        ;;
    cleanup-all)
        cleanup_all
        ;;
    wakeup)
        wakeup
        ;;
    *)
        show_help
        exit 1
        ;;
esac
