# 🚀 Rocket.Chat on OpenShift — Zero Privilege Deployment

[![OpenShift](https://img.shields.io/badge/OpenShift-4.x-red?logo=redhatopenshift)](https://www.redhat.com/en/technologies/cloud-computing/openshift)
[![Rocket.Chat](https://img.shields.io/badge/Rocket.Chat-8.x-red?logo=rocketdotchat&logoColor=white)](https://rocket.chat)
[![SCC](https://img.shields.io/badge/SCC-restricted-brightgreen)](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
[![MongoDB](https://img.shields.io/badge/MongoDB-8.2-47A248?logo=mongodb&logoColor=white)](https://www.mongodb.com)
[![Node.js](https://img.shields.io/badge/Node.js-22.x-339933?logo=nodedotjs&logoColor=white)](https://nodejs.org)
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
```

Your data persists in the PVCs — only the pods are stopped during hibernation. Give Rocket.Chat a minute or two to reconnect to MongoDB after scaling up.

---

## ⚠️ Important: MongoDB Changes

> **January 2025 Update**: Bitnami has discontinued MongoDB images following the VMware/Broadcom acquisition. Rocket.Chat 8.x requires MongoDB 8.2+, which is no longer available from Bitnami. This deployment uses the official MongoDB Community Server image deployed separately from the Helm chart.

---

## ✨ Features

- ✅ Rocket.Chat 8.x with Node.js 22 + Meteor 3.0
- ✅ Runs as non-root (OpenShift restricted SCC compatible)
- ✅ Official MongoDB Community Server 8.2 (UBI9-based) with single-node replica set
- ✅ Helm chart with automatic SCC patching
- ✅ **Auto-detected hostname** — no manual route configuration needed
- ✅ Persistent storage for MongoDB data
- ✅ Auto-generated secure MongoDB credentials
- ✅ Real-time messaging via MongoDB change streams
- ✅ Startup-aware health probes — no restarts during first-run setup
- ✅ Optional admin pre-configuration — skip the setup wizard entirely
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

# Deploy! 🎉  (hostname is auto-detected)
./deploy.sh

# Or skip the setup wizard by pre-configuring an admin user and its password
./deploy.sh --admin-user admin --admin-pass 'MyP@ss1234567!'
```

The script auto-detects your namespace and apps domain, builds the route hostname, and saves all credentials (MongoDB + admin) to `rocketchat-credentials.txt`.

> **Override the hostname** if you need a custom name:
> ```bash
> ./deploy.sh --host my-chat.apps.sandbox-m2.ll9k.p1.openshiftapps.com
> ```

### Option 2: Full OpenShift Cluster

For production or self-managed clusters:

```bash
# Create namespace
oc new-project rocketchat

# Deploy — hostname is auto-detected from cluster config
./deploy.sh

# Or deploy with admin pre-configured
./deploy.sh --admin-user admin --admin-pass 'MyP@ss1234567!'
```

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     OpenShift Route                         │
│                  (TLS edge termination)                     │
│          auto-detected: <release>-<ns>.<apps-domain>        │
└─────────────────────────┬───────────────────────────────────┘
                          │ :443 → :3000
┌─────────────────────────▼───────────────────────────────────┐
│                   Rocket.Chat Pod                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │           Node.js 22 + Meteor 3.0                    │   │
│  │                   (port 3000)                        │   │
│  │                                                      │   │
│  │   • Web interface                                    │   │
│  │   • REST API                                         │   │
│  │   • Real-time messaging (WebSocket)                  │   │
│  │   • File uploads                                     │   │
│  │   • /health endpoint for probes                      │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                          │
                          │ :27017
┌─────────────────────────▼───────────────────────────────────┐
│                    MongoDB Pod                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │        MongoDB Community Server 8.2 (UBI9)           │  │
│  │     mongodb/mongodb-community-server:8.2-ubi9        │  │
│  │          Single-node replica set (rs0)               │  │
│  │          Change streams for real-time events          │  │
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

### Hostname Auto-Detection

The deploy script resolves the route hostname automatically using three strategies (in order):

1. **Cluster ingress config** — `oc get ingresses.config/cluster` (works on full clusters)
2. **API server URL** — infers `apps.<cluster>` from `api.<cluster>` (works on Developer Sandbox)
3. **Existing routes** — parses the domain from any route already in the namespace

The resulting hostname follows the pattern: `rocketchat-<namespace>.<apps-domain>`

Override with `--host` if you need a custom name.

### Admin Setup (Skip the Wizard)

By default, Rocket.Chat shows a 4-step setup wizard on first launch. You can skip it entirely by passing `--admin-user` to the deploy script, which pre-configures the admin account and marks setup as complete:

```bash
# Auto-generate a password (saved to rocketchat-credentials.txt)
./deploy.sh --admin-user admin --admin-email admin@example.com

# Or provide your own password (must meet Rocket.Chat complexity requirements)
./deploy.sh --admin-user admin --admin-pass 'MySecureP@ss123!' --admin-email admin@example.com
```

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--admin-user` | No | — | Admin username; enables wizard skip when set |
| `--admin-pass` | No | (generated) | Admin password; auto-generated if omitted |
| `--admin-email` | No | `admin@example.com` | Admin email address |

When `--admin-user` is provided, the script injects these environment variables into the Rocket.Chat pod:

| Env Var | Purpose |
|---------|---------|
| `ADMIN_USERNAME` | Creates the admin account |
| `ADMIN_PASS` | Sets the admin password |
| `ADMIN_EMAIL` | Sets the admin email |
| `OVERWRITE_SETTING_Show_Setup_Wizard` | Set to `completed` to skip the wizard |

> **Password complexity**: Rocket.Chat requires at least 14 characters with uppercase, lowercase, number, and symbol. The auto-generated password meets these requirements. If you provide your own, make sure it does too — otherwise the admin account won't be created and you'll see the wizard anyway.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MONGO_URL` | (auto-configured) | MongoDB connection string |
| `MONGO_OPLOG_URL` | (auto-configured) | MongoDB oplog URL for real-time |
| `ROOT_URL` | (auto-detected) | External URL for Rocket.Chat |
| `PORT` | `3000` | Application port |
| `ADMIN_USERNAME` | — | Admin user (set via `--admin-user`) |
| `ADMIN_PASS` | — | Admin password (set via `--admin-pass`) |
| `ADMIN_EMAIL` | — | Admin email (set via `--admin-email`) |

### Persistent Volumes

| PVC | Size | Purpose |
|-----|------|---------|
| `mongodb-data` | 10Gi | MongoDB data storage |

### Health Probes

The deployment uses tuned health probes to prevent pod restarts during Rocket.Chat's first-run setup (admin registration, index creation, migrations):

| Probe | Path | Initial Delay | Period | Timeout | Failure Threshold |
|-------|------|---------------|--------|---------|-------------------|
| Liveness | `/health` | 120s | 15s | 10s | 6 |
| Readiness | `/health` | 30s | 10s | 5s | 6 |

MongoDB uses a `startupProbe` (30 attempts × 5s = 150s window) that gates liveness/readiness checks until the database is fully initialised.

### MongoDB & Change Streams

MongoDB runs as a single-node replica set (`rs0`) to enable change streams for real-time events. The deploy script automatically initializes the replica set, configures keyFile authentication, and injects the `MONGO_OPLOG_URL` environment variable.

> **Note:** The Rocket.Chat admin panel may show "oplog Disabled" — this is a **cosmetic label** from before Meteor 3.0. Rocket.Chat 8.x uses MongoDB change streams (via the replica set) instead of direct oplog tailing. Real-time messaging works correctly.

### Helm Values

The deploy script patches the official Rocket.Chat Helm chart to work with OpenShift's restricted SCC by removing hardcoded `runAsUser: 999` and `fsGroup: 999` values.

Key values passed to Helm:

```yaml
mongodb:
  enabled: false          # Using external MongoDB
microservices:
  enabled: false          # Monolithic mode (single pod)
nats:
  enabled: false          # Not needed without microservices
externalMongodbUrl: mongodb://admin:<password>@mongodb:27017/rocketchat?authSource=admin&replicaSet=rs0
host: <auto-detected>
```

---

## 🔧 Management Commands

```bash
# View MongoDB credentials
cat rocketchat-credentials.txt

# Or retrieve from secret
oc get secret mongodb-secret -o jsonpath='{.data.MONGODB_INITDB_ROOT_PASSWORD}' | base64 -d

# Check Rocket.Chat logs
oc logs deployment/rocketchat-rocketchat -f

# Check MongoDB logs
oc logs deployment/mongodb -f

# Access MongoDB shell
oc exec -it deployment/mongodb -- mongosh "mongodb://admin:$(oc get secret mongodb-secret -o jsonpath='{.data.MONGODB_INITDB_ROOT_PASSWORD}' | base64 -d)@localhost:27017/admin"

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
- **Probe failures during first run**: The refactored probes should prevent this, but if you see restarts during admin setup, increase `livenessProbe.initialDelaySeconds` further

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

### Hostname Auto-Detection Failures

If the deploy script can't determine the apps domain:

```bash
# Check what the script sees
oc whoami --show-server
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'

# Fall back to explicit hostname
./deploy.sh --host rocketchat.apps.mycluster.example.com
```

---

## 🚀 Production Recommendations

1. **MongoDB High Availability** — Use MongoDB Community Operator for multi-node replica sets
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
- MongoDB runs as a single-node replica set; for HA, consider the MongoDB Community Operator
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