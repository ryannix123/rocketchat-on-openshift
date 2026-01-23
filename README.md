# 🚀 RocketChat on OpenShift

A guide to deploying RocketChat on Red Hat OpenShift using [RocketChat's official Helm chart](https://github.com/RocketChat/helm-charts).

> ⚠️ **January 2025 Update**: Bitnami has discontinued MongoDB images following the VMware/Broadcom acquisition. RocketChat 8.x requires MongoDB 7.0+, which is no longer available from Bitnami. This guide uses the official MongoDB Community Server image deployed separately from the Helm chart.

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

### Waking Up Your Deployment

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

# Edit values.yml with your domain and namespace
# Edit mongodb-standalone.yaml with a secure password

# Run setup and deploy
chmod +x deploy.sh
./deploy.sh deploy
```

## 📋 Why This Approach?

RocketChat's Helm chart has two issues that prevent it from working on OpenShift out of the box:

1. **Bitnami MongoDB Deprecation**: The bundled Bitnami MongoDB subchart only provides MongoDB 6.0, but RocketChat 8.x requires MongoDB 7.0+. Bitnami has stopped publishing new MongoDB images.

2. **Hardcoded Security Contexts**: The Helm chart hardcodes `runAsUser: 999` and `fsGroup: 999`, which conflict with OpenShift's restricted Security Context Constraints (SCC). OpenShift requires UIDs within a project-specific range (e.g., 1006350000-1006359999).

**Our solution**:
- Deploy MongoDB separately using the official `mongodb/mongodb-community-server:8.0-ubi9` image
- Patch the RocketChat Helm chart locally to remove hardcoded security contexts
- Connect RocketChat to the external MongoDB instance

## 🚢 Deployment Steps

### 1️⃣ Create your OpenShift project

```bash
oc new-project rocketchat
# Or use your existing project
oc project <your-project>
```

### 2️⃣ Deploy MongoDB

Deploy MongoDB using the official MongoDB Community Server image (UBI-based for OpenShift compatibility):

```bash
oc apply -f mongodb-standalone.yaml
```

Wait for MongoDB to be ready:

```bash
oc get pods -w
# Wait until mongodb pod shows Running 1/1
```

### 3️⃣ Pull and patch the RocketChat Helm chart

The Helm chart has hardcoded security context values (`runAsUser: 999`, `fsGroup: 999`) that conflict with OpenShift's Security Context Constraints. Run the deploy script to pull and patch the chart:

```bash
chmod +x deploy.sh
./deploy.sh setup
```

This script:
- Adds the RocketChat Helm repository
- Pulls the chart locally
- Comments out the hardcoded security contexts in `rocketchat/values.yaml`

### 4️⃣ Deploy RocketChat

Update `values.yml` with your domain and MongoDB password, then deploy:

```bash
# Deploy everything (MongoDB + RocketChat)
./deploy.sh deploy

# Or deploy manually:
# oc apply -f mongodb-standalone.yaml -n <your-namespace>
# oc rollout status deployment/mongodb -n <your-namespace>
# helm install rocketchat ./rocketchat -f values.yml -n <your-namespace>
```

### 5️⃣ Access your RocketChat instance

Get the route URL:

```bash
oc get route -n <your-namespace>
```

Open the URL in your browser to complete the RocketChat setup wizard.

## 📁 Configuration Files

### mongodb-standalone.yaml

Deploys MongoDB 8.0 using the official UBI-based image:

```yaml
---
# MongoDB Secret
apiVersion: v1
kind: Secret
metadata:
  name: mongodb-secret
type: Opaque
stringData:
  MONGO_INITDB_ROOT_USERNAME: admin
  MONGO_INITDB_ROOT_PASSWORD: <your-secure-password>

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
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mongodb
  template:
    metadata:
      labels:
        app: mongodb
    spec:
      containers:
        - name: mongodb
          image: mongodb/mongodb-community-server:8.0-ubi9
          ports:
            - containerPort: 27017
              name: mongodb
          env:
            - name: MONGO_INITDB_ROOT_USERNAME
              valueFrom:
                secretKeyRef:
                  name: mongodb-secret
                  key: MONGO_INITDB_ROOT_USERNAME
            - name: MONGO_INITDB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mongodb-secret
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
spec:
  ports:
    - port: 27017
      targetPort: 27017
      name: mongodb
  selector:
    app: mongodb
  type: ClusterIP
```

### values.yml

RocketChat Helm values for OpenShift with external MongoDB:

```yaml
# RocketChat values for OpenShift with external MongoDB

# Domain configuration - UPDATE THIS
host: rocketchat.apps.<your-cluster-domain>.com

# Ingress configuration
ingress:
  enabled: true
  annotations:
    route.openshift.io/termination: edge

# Disable built-in MongoDB - we deploy it separately
mongodb:
  enabled: false

# External MongoDB connection string - UPDATE PASSWORD
externalMongodbUrl: "mongodb://admin:<your-password>@mongodb.<your-namespace>.svc.cluster.local:27017/rocketchat?authSource=admin"
externalMongodbOplogUrl: "mongodb://admin:<your-password>@mongodb.<your-namespace>.svc.cluster.local:27017/local?authSource=admin"

# Let OpenShift handle security contexts
podSecurityContext: {}
containerSecurityContext: {}
securityContext: {}

serviceAccount:
  create: true

# Resource limits (adjust as needed)
resources:
  requests:
    memory: "512Mi"
    cpu: "250m"
  limits:
    memory: "2Gi"
    cpu: "1000m"
```

## 🧹 Cleanup

To remove the deployment:

```bash
# Remove RocketChat and MongoDB (keeps PVCs/data)
./deploy.sh cleanup

# Remove everything including persistent data
./deploy.sh cleanup-all
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
PLEASE UPGRADE TO VERSION 7.0 OR LATER
```

Ensure you're using the standalone MongoDB deployment with `mongodb/mongodb-community-server:8.0-ubi9`, not the Bitnami subchart.

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
oc run mongo-test --rm -it --image=mongodb/mongodb-community-server:8.0-ubi9 --restart=Never -- \
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
