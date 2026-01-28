# 🚀 Rocket.Chat on OpenShift — Zero Privilege Deployment

[![OpenShift](https://img.shields.io/badge/OpenShift-4.x-red?logo=redhatopenshift)](https://www.redhat.com/en/technologies/cloud-computing/openshift)
[![Rocket.Chat](https://img.shields.io/badge/Rocket.Chat-8.x-red?logo=rocketdotchat&logoColor=white)](https://rocket.chat)
[![SCC](https://img.shields.io/badge/SCC-restricted-brightgreen)](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
[![MongoDB](https://img.shields.io/badge/MongoDB-8.2-47A248?logo=mongodb&logoColor=white)](https://www.mongodb.com)
[![Node.js](https://img.shields.io/badge/Node.js-20.x-339933?logo=nodedotjs&logoColor=white)](https://nodejs.org)
[![Helm](https://img.shields.io/badge/Helm-Chart-0F1689?logo=helm&logoColor=white)](https://helm.sh)

> **Deploy Rocket.Chat on OpenShift without ANY elevated privileges.** No `anyuid`. No `privileged`. Just pure, security-hardened container goodness designed for multi-tenancy.

---

## 🆓 Red Hat Developer Sandbox

The [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox) is a **free** OpenShift environment perfect for testing Rocket.Chat:

- **Free tier** — No credit card required
- **Generous resources** — 14 GB RAM, 40 GB storage, 3 CPU cores
- **Latest OpenShift** — Always running a recent version (4.18+)
- **Auto-hibernation** — Deployments scale to zero after 12 hours of inactivity

### Waking Up Your Deployment

When you return after the sandbox has hibernated, your pods will be scaled down. Run this command to bring everything back up:

```bash
# Option 1: Use the deploy script
./deploy.sh wakeup

# Option 2: Manual commands (MongoDB must start first)
oc scale deployment mongodb --replicas=1
oc rollout status deployment/mongodb
oc scale deployment --all --replicas=1
oc scale statefulset --all --replicas=1
```

Your data persists in the PVCs — only the pods are stopped during hibernation. Give Rocket.Chat a minute or two to reconnect to MongoDB after scaling up.

---

## ⚠️ Important: MongoDB Changes

> **January 2025 Update**: Bitnami has discontinued MongoDB images following the VMware/Broadcom acquisition. Rocket.Chat 8.x requires MongoDB 8.2+, which is no longer available from Bitnami. This deployment uses the official MongoDB Community Server image deployed separately from the Helm chart.

---

## ✨ Features

- ✅ Rocket.Chat 8.x with Node.js 20 + Meteor 3.0
- ✅ Runs as non-root (OpenShift restricted SCC compatible)
- ✅ Official MongoDB Community Server 8.2 (UBI9-based)
- ✅ Helm chart with automatic SCC patching
- ✅ Persistent storage for MongoDB data
- ✅ Auto-generated secure MongoDB credentials
- ✅ Works on Developer Sandbox (free tier!)

---

## 🚀 Quick Start

### Option 1: Developer Sandbox (Easiest)

Perfect for testing or personal use on the [free Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox):

```bash
# Clone the repo
git clone https://github.com/ryannix123/rocketchat-on-openshift.git
cd rocketchat-on-openshift

# Login to your sandbox
oc login --token=YOUR_TOKEN --server=https://api.sandbox.openshiftapps.com:6443

# Deploy! 🎉
./deploy.sh --host rocketchat.apps.your-sandbox.openshiftapps.com
```

The script auto-detects your namespace and saves credentials to `rocketchat-credentials.txt`.

### Option 2: Full OpenShift Cluster

For production or self-managed clusters:

```bash
# Create namespace
oc new-project rocketchat

# Find your cluster's apps domain
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'

# Deploy with your hostname
./deploy.sh --host rocketchat.apps.mycluster.example.com
```

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     OpenShift Route                         │
│                  (TLS edge termination)                     │
└─────────────────────────┬───────────────────────────────────┘
                          │ :443 → :3000
┌─────────────────────────▼───────────────────────────────────┐
│                   Rocket.Chat Pod                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │           Node.js 20 + Meteor 3.0                    │   │
│  │                   (port 3000)                        │   │
│  │                                                      │   │
│  │   • Web interface                                    │   │
│  │   • REST API                                         │   │
│  │   • Real-time messaging (WebSocket)                  │   │
│  │   • File uploads                                     │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ :27017
┌─────────────────────────▼───────────────────────────────────┐
│                    MongoDB Pod                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │        MongoDB Community Server 8.2 (UBI9)           │  │
│  │     mongodb/mongodb-community-server:8.2-ubi9        │  │
│  └─────────────────────────┬────────────────────────────┘  │
│                            │                               │
│  ┌─────────────────────────▼────────────────────────────┐  │
│  │           Database PVC (10Gi RWO)                    │  │
│  │   /data/db                                           │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 📁 Files

| File | Description |
|------|-------------|
| `deploy.sh` | Main deployment script (deploy, cleanup, wakeup) |
| `mongodb-standalone.yaml` | MongoDB manifest (reference — deploy.sh creates resources directly) |
| `values.yml` | Rocket.Chat Helm values (reference — deploy.sh passes values via --set) |

> **Note:** The `deploy.sh` script handles all configuration automatically. The YAML files are provided for reference and manual deployments.

---

## ⚙️ Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MONGO_URL` | (auto-configured) | MongoDB connection string |
| `MONGO_OPLOG_URL` | (auto-configured) | MongoDB oplog URL for real-time |
| `ROOT_URL` | (from --host flag) | External URL for Rocket.Chat |
| `PORT` | `3000` | Application port |

### Persistent Volumes

| PVC | Size | Purpose |
|-----|------|---------|
| `mongodb-pvc` | 10Gi | MongoDB data storage |

### Helm Values

The deploy script patches the official Rocket.Chat Helm chart to work with OpenShift's restricted SCC by removing hardcoded `runAsUser: 999` and `fsGroup: 999` values.

Key values passed to Helm:

```yaml
mongodb:
  enabled: false  # Using external MongoDB
externalMongodbUrl: mongodb://admin:<password>@mongodb:27017/rocketchat?authSource=admin
host: <your-hostname>
```

---

## 🔧 Management Commands

```bash
# View MongoDB credentials
cat rocketchat-credentials.txt

# Or retrieve from secret
oc get secret mongodb-secret -o jsonpath='{.data.password}' | base64 -d

# Check Rocket.Chat logs
oc logs deployment/rocketchat-rocketchat -f

# Check MongoDB logs
oc logs deployment/mongodb -f

# Access MongoDB shell
oc exec -it deployment/mongodb -- mongosh "mongodb://admin:$(oc get secret mongodb-secret -o jsonpath='{.data.password}' | base64 -d)@localhost:27017/admin"

# Test MongoDB connection
oc exec deployment/mongodb -- mongosh "mongodb://admin:<password>@localhost:27017/admin" --eval "db.runCommand({ping:1})"

# Get route URL
oc get route rocketchat -o jsonpath='{.spec.host}'

# Wake up after hibernation
./deploy.sh wakeup

# Cleanup (removes everything including data)
./deploy.sh cleanup
```

---

## 🔒 Security

This deployment runs under OpenShift's most restrictive security policy:

| Security Feature | Status |
|------------------|--------|
| Runs as non-root | ✅ |
| Random UID from namespace range | ✅ |
| All capabilities dropped | ✅ |
| No privilege escalation | ✅ |
| Seccomp profile enforced | ✅ |
| Works on Developer Sandbox | ✅ |

Verify your deployment:

```bash
# Check SCC assignment (should show "restricted" or "restricted-v2")
oc get pod -l app.kubernetes.io/name=rocketchat -o jsonpath='{.items[*].metadata.annotations.openshift\.io/scc}'

# Verify non-root UID
oc exec deployment/rocketchat-rocketchat -- id
```

---

## 🛡️ Securing Access with IP Whitelisting

OpenShift makes it easy to restrict access to your Rocket.Chat instance by IP address using route annotations — no firewall rules or external load balancer configuration needed.

### Allow Only Specific IPs

```bash
# Allow access only from your office and home IPs
oc annotate route rocketchat \
  haproxy.router.openshift.io/ip_whitelist="203.0.113.50 198.51.100.0/24"
```

### Common Use Cases

| Scenario | Annotation Value |
|----------|------------------|
| Single IP | `203.0.113.50` |
| Multiple IPs | `203.0.113.50 198.51.100.25` |
| CIDR range | `10.0.0.0/8` |
| Mixed | `203.0.113.50 192.168.1.0/24 10.0.0.0/8` |

### Remove Restriction

```bash
oc annotate route rocketchat haproxy.router.openshift.io/ip_whitelist-
```

### Verify Configuration

```bash
oc get route rocketchat -o jsonpath='{.metadata.annotations.haproxy\.router\.openshift\.io/ip_whitelist}'
```

This is a great way to lock down a POC or demo instance to only your team's IPs without any infrastructure changes.

---

## 🐛 Troubleshooting

### Security Context Constraint Errors

If you see errors like:
```
unable to validate against any security context constraint: 
.spec.securityContext.fsGroup: Invalid value: []int64{999}: 999 is not an allowed group
```

This means the Helm chart still has hardcoded security contexts. Re-run the setup or verify the patch:

```bash
grep -n "999" rocketchat/values.yaml
```

If you see uncommented `runAsUser: 999` or `fsGroup: 999`, run `./deploy.sh setup` again.

### MongoDB Version Errors

If Rocket.Chat logs show:
```
YOUR CURRENT MONGODB VERSION IS NOT SUPPORTED BY ROCKET.CHAT,
PLEASE UPGRADE TO VERSION 8.2 OR LATER
```

Ensure you're using the standalone MongoDB deployment with `mongodb/mongodb-community-server:8.2-ubi9`, not the Bitnami subchart.

### Pod CrashLoopBackOff

```bash
# Check logs
oc logs deployment/rocketchat-rocketchat
oc logs deployment/rocketchat-rocketchat --previous
oc logs deployment/mongodb
```

Common issues:
- **MongoDB connection errors**: Verify MongoDB pod is running first
- **Resource limitations**: Developer Sandbox has memory limits; check if pods are being OOMKilled

### MongoDB Connection Errors

```bash
# Verify MongoDB is running
oc get pods -l app=mongodb

# Check MongoDB service
oc get svc mongodb

# Test connection from inside the cluster
oc run mongo-test --rm -it --image=mongodb/mongodb-community-server:8.2-ubi9 --restart=Never -- \
  mongosh "mongodb://admin:<password>@mongodb:27017/admin" --eval "db.runCommand({ping:1})"
```

---

## 🚀 Production Recommendations

1. **MongoDB Replication** — Use MongoDB Community Operator for replica sets
2. **Object Storage** — Configure S3-compatible backend for file uploads
3. **SMTP Configuration** — Set up email notifications
4. **Resource Limits** — Tune based on user count
5. **Backup Strategy** — Implement OADP or Velero for disaster recovery

### Resource Sizing

| Users | CPU | Memory | DB Storage |
|-------|-----|--------|------------|
| 1-50 | 500m | 1Gi | 5Gi |
| 50-200 | 1 | 2Gi | 10Gi |
| 200-500 | 2 | 4Gi | 25Gi |
| 500+ | 4+ | 8Gi+ | 50Gi+ |

---

## 📝 Notes

- This deployment uses Rocket.Chat's Starter plan (free for up to 50 users)
- For production, consider MongoDB with replication (MongoDB Community Operator)
- Always backup your MongoDB data before upgrading!
- The Developer Sandbox resets after 30 days of inactivity

---

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-fix`)
3. Commit your changes (`git commit -m 'Add amazing fix'`)
4. Push to the branch (`git push origin feature/amazing-fix`)
5. Open a Pull Request

---

## 📚 References

- [Rocket.Chat Documentation](https://docs.rocket.chat/)
- [Rocket.Chat Helm Charts](https://github.com/RocketChat/helm-charts)
- [MongoDB Community Server Images](https://hub.docker.com/r/mongodb/mongodb-community-server)
- [OpenShift SCC Documentation](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
- [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox)

---

## 🙏 Acknowledgments

- [Rocket.Chat](https://rocket.chat) for the amazing open source team communication platform
- [MongoDB](https://www.mongodb.com) for the Community Server images
- Red Hat for OpenShift and the Developer Sandbox
- The patterns from [nextcloud-on-openshift](https://github.com/ryannix123/nextcloud-on-openshift)

---

**⭐ If this saved you hours of debugging, consider giving it a star! ⭐**
