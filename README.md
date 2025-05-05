# 🚀 RocketChat on OpenShift

A guide to deploying RocketChat on Red Hat OpenShift using [RocketChat's official Helm chart](https://github.com/RocketChat/helm-charts).

## 🏝️ Getting a Free OpenShift Sandbox

Before you start, you can get a free OpenShift environment through Red Hat's Developer Sandbox:

1. Visit [developers.redhat.com/developer-sandbox](https://developers.redhat.com/developer-sandbox)
2. Click the "Start your sandbox for free" button
3. Sign in with your Red Hat account (or create one if you don't have it)
4. Complete the registration process
5. Once approved, click "Start using your sandbox"
6. Select the "DevSandbox" login option when prompted

The Developer Sandbox provides:
- A free OpenShift environment valid for 30 days
- 8-10 GB of memory and about 4 CPU cores
- Pre-configured developer tools
- No credit card required

**Note:** The Developer Sandbox has resource limitations but is perfect for testing RocketChat deployment before moving to a production environment.

## 🛠️ Prerequisites

- OpenShift cluster (no admin access required)
- Helm 3.x installed
- `oc` CLI tool configured

## 🚢 Deployment Steps

### 1️⃣ Add the RocketChat Helm repository

```bash
helm repo add rocketchat https://rocketchat.github.io/helm-charts
helm repo update
```

### 2️⃣ Create OpenShift-compatible values file

Create a file named `values.yml` with the following content. This file is necessary because:

1. **OpenShift Security Compatibility**: OpenShift uses Security Context Constraints (SCCs) that restrict pod execution. The standard RocketChat Helm chart needs adjustments to comply with these restrictions. Instead, we're telling the Helm chart not to specify explicit user IDs and group IDs that would conflict with OpenShift's security model.

2. **MongoDB Configuration**: RocketChat requires specific MongoDB settings (including credentials in array format) that must be explicitly configured. The values file lets OpenShift's security model handle the container security rather than trying to override it with potentially conflicting settings.

3. **Route Configuration**: We need to set up proper OpenShift Routes for external access.

4. **Custom Deployment Parameters**: The values file lets us customize the deployment without modifying the chart itself.

```yaml
# Domain configuration
host: rocketchat.your-apps-domain.com  # Replace with your actual domain

# Ingress configuration
ingress:
  enabled: true
  annotations:
    route.openshift.io/termination: edge

# Disable security contexts for OpenShift compatibility
securityContext:
  enabled: false

serviceAccount:
  create: true

# MongoDB configuration
mongodb:
  enabled: true
  auth:
    # MongoDB credentials as arrays (required in newer versions)
    usernames:
      - rocketchat
    passwords:
      - your-secure-password  # Replace with a secure password
    databases:
      - rocketchat
    rootPassword: your-secure-root-password  # Replace with a secure password
  
  # OpenShift compatibility settings
  securityContext:
    enabled: false
  podSecurityContext:
    enabled: false
  containerSecurityContext:
    enabled: false
  volumePermissions:
    enabled: false
  
  # For production, consider setting specific storage requirements
  persistence:
    enabled: true
    size: 8Gi
```

### 3️⃣ Deploy RocketChat

```bash
# Create a new project (optional)
oc new-project rocketchat

# Deploy using Helm
helm install rocketchat rocketchat/rocketchat -f values.yml -n rocketchat
```

### 4️⃣ Access your RocketChat instance

Once deployed, access your RocketChat instance at `https://rocketchat.your-apps-domain.com`.

## 🔧 Troubleshooting

### 💥 Pod CrashLoopBackOff

If pods enter CrashLoopBackOff state, check logs:

```bash
oc logs $(oc get pods -l "app.kubernetes.io/name=rocketchat" -o jsonpath='{.items[0].metadata.name}')
```

Common issues:
- **MongoDB connection errors**: Verify MongoDB pods are running
- **Security context issues**: Ensure all security contexts are disabled
- **Resource limitations**: Check if pods are hitting resource limits

### 🔌 MongoDB Connection Errors

If RocketChat can't connect to MongoDB, check that the MongoDB service exists:

```bash
oc get svc | grep mongodb
```

Ensure MongoDB pods are running:

```bash
oc get pods | grep mongodb
```

## 📝 Notes

- This deployment provides a free RocketChat Starter plan (limited to 50 users)
- For production deployments, consider using external MongoDB instance
- Always backup your data before upgrading!

## ❓ Why a Custom Values File Matters

The `values.yml` file is critical for successful deployment on OpenShift because:

1. **OpenShift Security**: OpenShift enforces stricter security policies than standard Kubernetes. Our values file disables security contexts that would conflict with OpenShift's Security Context Constraints.

2. **Application Configuration**: It allows us to configure hostnames, MongoDB credentials, and persistence options without modifying the original chart.

3. **Troubleshooting**: Many common deployment issues in OpenShift can be solved with proper values configuration rather than custom chart modifications.

4. **Reproducibility**: Having a values file makes it easy to recreate or upgrade your deployment consistently.

## 📜 License Considerations

RocketChat versions 6.5+ use a "Starter plan" licensing model that's free for up to 50 users. Beyond that, you'll need to purchase a Pro or Enterprise license.
