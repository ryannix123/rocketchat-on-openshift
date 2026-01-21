#!/bin/bash
# setup.sh - Pulls and patches the RocketChat Helm chart for OpenShift
#
# This script:
#   1. Adds the RocketChat Helm repository
#   2. Pulls the chart locally
#   3. Patches out hardcoded security contexts that conflict with OpenShift SCCs
#
# Usage: ./setup.sh

set -e

echo "🚀 RocketChat on OpenShift - Chart Setup"
echo "========================================="
echo ""

# Add Helm repo
echo "📦 Adding RocketChat Helm repository..."
helm repo add rocketchat https://rocketchat.github.io/helm-charts
helm repo update

# Pull the chart
echo "📥 Pulling RocketChat Helm chart..."
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
echo ""
echo "📋 Next steps:"
echo "   1. Update values.yml with your domain and MongoDB password"
echo "   2. Deploy MongoDB:  oc apply -f mongodb-standalone.yaml"
echo "   3. Wait for MongoDB: oc get pods -w"
echo "   4. Deploy RocketChat: helm install rocketchat ./rocketchat -f values.yml -n <your-namespace>"
echo ""
echo "📖 See README.md for full instructions and troubleshooting."
