# 🚀 RocketChat on OpenShift
[![OpenShift](https://img.shields.io/badge/OpenShift-4.x-red?logo=redhatopenshift)](https://www.redhat.com/en/technologies/cloud-computing/openshift)
[![Rocket.Chat](https://img.shields.io/badge/Rocket.Chat-8.x-red?logo=rocketdotchat&logoColor=white)](https://rocket.chat)
[![SCC](https://img.shields.io/badge/SCC-restricted-brightgreen)](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
[![MongoDB](https://img.shields.io/badge/MongoDB-8.2-47A248?logo=mongodb&logoColor=white)](https://www.mongodb.com)
[![Node.js](https://img.shields.io/badge/Node.js-20.x-339933?logo=nodedotjs&logoColor=white)](https://nodejs.org)
[![Helm](https://img.shields.io/badge/Helm-Chart-0F1689?logo=helm&logoColor=white)](https://helm.sh)

A guide to deploying RocketChat on Red Hat OpenShift using [RocketChat's official Helm chart](https://github.com/RocketChat/helm-charts).

> ⚠️ **January 2025 Update**: Bitnami has discontinued MongoDB images following the VMware/Broadcom acquisition. RocketChat 8.x requires MongoDB 8.2+, which is no longer available from Bitnami. This guide uses the official MongoDB Community Server image deployed separately from the Helm chart.

## 🏝️ Getting a Free OpenShift Sandbox

Before you start, you can get a free OpenShift environment through Red Hat's Developer Sandbox:

1. Visit [developers.redhat.com/developer-sandbox](https://developers.redhat.com/developer-sandbox)
2. Click the "Start your sandbox for free" button
3. Sign in with your Red Hat account (or create one if you don't have it)
4. Complete the registration process
5. Once approved, click "Start using your sandbox"
6. Select the "DevSandbox" login option when prompted

The Developer Sandbox provides:

* A free OpenShift environment valid for 30 days
* 8-10 GB of memory and about 4 CPU cores
* Pre-configured developer tools
* No credit card required
* **Auto-hibernation** — Deployments scale to zero after 12 hours of inactivity

### 😴 Waking Up Your Deployment

When you return after the sandbox has hibernated, your pods will be scaled to zero. Use the deploy script or run the commands manually:

```bash
# Option 1: Use the deploy script
./deploy.sh wakeup

# Option 2: Manual commands (uses current project)
oc scale deployment mongodb --replicas=1
oc rollout status deployment/mongodb
oc scale deployment --all --replicas=1
oc scale statefulset --all --replicas=1
```

Your data persists in the PVCs — only the pods are stopped during hibernation. Give RocketChat a minute or two to reconnect to MongoDB after scaling up.

## 🛠️ Prerequisites

* OpenShift cluster (no admin access required)
* Helm 3.x installed
* `oc` CLI tool configured

## ⚡ Quick Start

```bash
# Clone this repo
git clone https://github.com/ryannix123/rocketchat-on-openshift.git
cd rocketchat-on-openshift

# Deploy
chmod +x deploy.sh
./deploy.sh --host rocketchat.apps.<your-cluster-domain>.com
```

That's it! The script will:
- Pull and patch the Helm chart automatically
- Generate a secure MongoDB password
- Deploy MongoDB and RocketChat
- Configure everything for your namespace

## 📋 Why This Approach?

RocketChat's Helm chart has two issues that prevent it from working on OpenShift out of the box:

1. **Bitnami MongoDB Deprecation**: The bundled Bitnami MongoDB subchart only provides MongoDB 6.0, but RocketChat 8.x requires MongoDB 8.2+. Bitnami has stopped publishing new MongoDB images.

2. **Hardcoded Security Contexts**: The Helm chart hardcodes `runAsUser: 999` and `fsGroup: 999`, which conflict with OpenShift's restricted Security Context Constraints (SCC). OpenShift requires UIDs within a project-specific range (e.g., 1006350000-1006359999).

**Our solution**:
- Deploy MongoDB separately using the official `mongodb/mongodb-community-server:8.2-ubi9` image
- Patch the RocketChat Helm chart locally to remove hardcoded security contexts
- Connect RocketChat to the external MongoDB instance

## 🚢 Deployment Steps

### 1️⃣ Create your OpenShift project

```bash
oc new-project rocketchat
# Or use your existing project
oc project <your-project>
```

### 2️⃣ Find your OpenShift apps domain

```bash
# Get your cluster's apps domain
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'
# Example output: apps.rm3.7wse.p1.openshiftapps.com
```

### 3️⃣ Deploy RocketChat

```bash
./deploy.sh --host rocketchat.apps.<your-cluster-domain>.com

# Example for Developer Sandbox:
./deploy.sh --host rocketchat.apps.rm3.7wse.p1.openshiftapps.com
```

The script automatically:
- Pulls and patches the Helm chart (if not already done)
- Generates a secure MongoDB password (stored in a Kubernetes Secret)
- Deploys MongoDB with the official `mongodb/mongodb-community-server:8.2-ubi9` image
- Deploys RocketChat configured to connect to MongoDB
- Uses your current OpenShift project/namespace

### 4️⃣ Access your RocketChat instance

Get the route URL:

```bash
oc get route -n <your-namespace>
```

Open the URL in your browser to complete the RocketChat setup wizard.

## 📁 Files in This Repository

| File | Description |
|------|-------------|
| `deploy.sh` | Main deployment script (deploy, cleanup, wakeup) |
| `mongodb-standalone.yaml` | MongoDB manifest (reference only - deploy.sh creates resources directly) |
| `values.yml` | RocketChat Helm values (reference only - deploy.sh passes values via --set) |
| `README.md` | This documentation |

> **Note:** The `deploy.sh` script handles all configuration automatically. The YAML files are provided for reference and manual deployments.

## 🧹 Cleanup

To remove the entire deployment including all data:

```bash
./deploy.sh cleanup
```

## 🔧 Troubleshooting

### 💥 Security Context Constraint Errors

If you see errors like:
```
unable to validate against any security context constraint: 
.spec.securityContext.fsGroup: Invalid value: []int64{999}: 999 is not an allowed group
```

This means the Helm chart still has hardcoded security contexts. Re-run the setup script or verify the patch was applied:

```bash
grep -n "999" rocketchat/values.yaml
```

If you see uncommented `runAsUser: 999` or `fsGroup: 999`, run `./deploy.sh setup` again or manually comment out those lines.

### 💥 MongoDB Version Errors

If RocketChat logs show:
```
YOUR CURRENT MONGODB VERSION IS NOT SUPPORTED BY ROCKET.CHAT,
PLEASE UPGRADE TO VERSION 8.2 OR LATER
```

Ensure you're using the standalone MongoDB deployment with `mongodb/mongodb-community-server:8.2-ubi9`, not the Bitnami subchart.

### 💥 Pod CrashLoopBackOff

Check the logs:

```bash
oc logs deployment/rocketchat-rocketchat
oc logs deployment/mongodb
```

Common issues:
- **MongoDB connection errors**: Verify MongoDB pod is running and the connection string in `values.yml` is correct
- **Resource limitations**: Developer Sandbox has memory limits; check if pods are being OOMKilled

### 🔌 MongoDB Connection Errors

Verify MongoDB is accessible:

```bash
# Check MongoDB pod
oc get pods | grep mongodb

# Check MongoDB service
oc get svc mongodb

# Test connection from inside the cluster
oc run mongo-test --rm -it --image=mongodb/mongodb-community-server:8.2-ubi9 --restart=Never -- \
  mongosh "mongodb://admin:<password>@mongodb:27017/admin" --eval "db.runCommand({ping:1})"
```

## 📝 Notes

* This deployment uses RocketChat's Starter plan (free for up to 50 users)
* For production, consider using MongoDB with replication (MongoDB Community Operator)
* Always backup your MongoDB data before upgrading!
* The Developer Sandbox resets after 30 days of inactivity

## 🔗 References

* [RocketChat Helm Charts](https://github.com/RocketChat/helm-charts)
* [MongoDB Community Server Images](https://hub.docker.com/r/mongodb/mongodb-community-server)
* [RocketChat Forum: Moving from Bitnami to Official MongoDB](https://forums.rocket.chat/t/action-required-moving-from-bitnami-to-official-mongodb-chart/22679)
* [OpenShift Developer Sandbox](https://developers.redhat.com/developer-sandbox)

## 📜 License

This guide is provided as-is. RocketChat versions 6.5+ use a "Starter plan" licensing model that's free for up to 50 users.
