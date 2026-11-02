# Deploying devops-cia on Azure (Jenkins VM + Kubernetes VM)

Everything runs on **two Azure VMs** in one virtual network:

```
 Developer ──git push──▶ GitHub ──poll / webhook──▶  VM 1: jenkins-vm  (10.0.1.4, public IP, port 8080)
                                                      │ 1 Checkout  2 Maven build+test  3 package
                                                      │ 4 docker build  5 docker push ──▶ Docker Hub
                                                      │ 6 ansible-playbook  (SSH over the VNet, port 22)
                                                      ▼
                                          VM 2: app-vm  (10.0.1.5, public IP, port 80)
                                          └─ k3s (single-node Kubernetes)
                                              ├─ Deployment  devops-demo  (2 pods, rolling updates, probes)
                                              ├─ Service     devops-demo  (ClusterIP :80 → pod :8080)
                                              └─ Ingress     (Traefik, port 80) ──▶ http://<APP_VM_PUBLIC_IP>/
                                                         ▲ image pulled from Docker Hub
```

**Why k3s?** You asked for exactly 2 VMs. k3s is a certified, lightweight Kubernetes distribution that installs in one
command on a normal VM and includes `kubectl`, the container runtime and an ingress controller. (AKS would be a managed
alternative, but it creates its own node VMs and is a different setup.)

### What was added/changed in the project

| Path | What |
|------|------|
| `k8s/` | **New.** Namespace, Deployment (2 replicas, health probes, resource limits, zero-downtime rolling update), Service, Ingress |
| `ansible/setup-server.yml` | Now installs **k3s** on the app VM (was: Docker) |
| `ansible/deploy.yml` | Now copies `k8s/`, injects the new image tag, runs `kubectl apply`, waits for rollout, **auto-rolls back on failure** |
| `Jenkinsfile` | AWS → Azure: `azureuser`, JDK 21 tool, credential IDs `app-vm-ssh-key` / `app-vm-ip`, stage "Deploy to Kubernetes" |
| `azure/provision.sh` | **New.** Creates all Azure resources with the `az` CLI |
| `eks-cluster.yaml` | Removed (AWS-only, not used) |

---

## 1. Prerequisites

1. **Azure account** with an active subscription (free trial / Azure for Students works).
2. **Azure CLI** on your laptop: <https://learn.microsoft.com/cli/azure/install-azure-cli>, then `az login`.
   Check: `az account show` (make sure it's the subscription you want; change with `az account set --subscription "<name>"`).
3. **Docker Hub account + access token**: Account Settings → Personal access tokens → *Generate new token* → **Read & Write**. Save the token.
   Create a **public** repository named `devops-demo` (or let the first push create it; keep it public so Kubernetes can pull without credentials).
4. **GitHub repo** (yours already: `https://github.com/Amrithseb2006/calculator-devops`).
5. An SSH client (Linux/macOS terminal, or Windows PowerShell / WSL / Git Bash).
6. Your **public IP** (open <https://ifconfig.me>). Used to restrict SSH and the Jenkins UI to you.

---

## 2. Edit the Jenkinsfile and push the code to GitHub

1. Open `Jenkinsfile` and change this line to your Docker Hub username:
   ```groovy
   DOCKERHUB_USER = 'your-dockerhub-username'
   ```
2. Commit and push everything (new `k8s/`, `azure/`, changed Ansible files):
   ```bash
   cd devops-cia
   git add -A
   git commit -m "Move to Azure + Kubernetes (k3s)"
   git push origin main
   ```

---

## 3. Create the Azure infrastructure (2 VMs)

### 3.1 Run the script (recommended)

Run it on your **laptop** (not Azure Cloud Shell, because Cloud Shell has a different public IP than yours and you
could not SSH in from your laptop afterwards).

```bash
cd devops-cia
export MY_IP="<your public IP from ifconfig.me>"
bash azure/provision.sh
```

Takes ~3-5 minutes. At the end it prints both public IPs. **Write them down**:

| Name | Value |
|------|-------|
| `JENKINS_IP` | public IP of `jenkins-vm` |
| `APP_IP` | public IP of `app-vm` |

On Windows PowerShell without bash, use WSL or Git Bash, or follow 3.4 (portal).

What it creates:

| Resource | Details |
|----------|---------|
| Resource group `devops-cia-rg` | Region `centralindia` (override: `LOCATION=southindia bash azure/provision.sh`) |
| VNet `devops-vnet` | `10.0.0.0/16`, subnet `10.0.1.0/24` |
| `jenkins-nsg` (firewall) | Allow SSH 22 + TCP 8080 **only from your IP** |
| `app-nsg` (firewall) | Allow SSH 22 from your IP, HTTP 80 from the internet |
| VM `jenkins-vm` | Ubuntu 24.04, `Standard_B2s` (2 vCPU / 4 GB), 30 GB disk, private IP `10.0.1.4`, static public IP |
| VM `app-vm` | Ubuntu 24.04, `Standard_B2s`, 30 GB disk, private IP `10.0.1.5`, static public IP |
| SSH key | `~/.ssh/azure_devops_key` (+ `.pub`), generated if missing. Admin user on both VMs: **`azureuser`** |

The VMs reach each other on the private network; Azure's default rules allow all traffic inside the VNet, so Jenkins → app SSH works with no extra rule.

### 3.2 Test SSH

```bash
ssh -i ~/.ssh/azure_devops_key azureuser@<JENKINS_IP>     # type yes, then exit
ssh -i ~/.ssh/azure_devops_key azureuser@<APP_IP>         # type yes, then exit
```
On Windows the key is at `C:\Users\<you>\.ssh\azure_devops_key`. If SSH complains about permissions: `chmod 600 ~/.ssh/azure_devops_key`.

### 3.3 If the script says the VM size is not available / quota exceeded

Some subscriptions (especially student/free) restrict sizes or regions.
```bash
az vm list-skus -l centralindia --size Standard_B --resource-type virtualMachines -o table
```
Pick a size whose *Restrictions* column is `None`, then re-run with it (delete the half-created group first:
`az group delete -n devops-cia-rg --yes`):
```bash
VM_SIZE=Standard_B2ms LOCATION=southindia bash azure/provision.sh
```
Minimum sensible size: **2 vCPU and 4 GB RAM** for Jenkins (Jenkins + Maven + Docker) and **2 GB+** for the k3s VM.

### 3.4 Portal alternative (no CLI)

Create the same things by hand in <https://portal.azure.com>: Resource group → Virtual network (`10.0.0.0/16`, subnet `10.0.1.0/24`)
→ two Network security groups (rules above) → two VMs (Ubuntu Server 24.04 LTS, size `B2s`, user `azureuser`,
*SSH public key* auth using the same key, same VNet/subnet, NSG = "Advanced" → pick the matching NSG; set the NIC
private IPs to static `10.0.1.4` and `10.0.1.5` under *Network interface → IP configurations*).

---

## 4. Set up VM 1: Jenkins

```bash
ssh -i ~/.ssh/azure_devops_key azureuser@<JENKINS_IP>
```

### 4.1 Install Java 21, Git, Maven, Docker, Ansible

```bash
sudo apt update && sudo apt -y upgrade
sudo apt install -y fontconfig openjdk-21-jdk git maven docker.io ansible
java -version && mvn -v && docker --version && ansible --version
```

### 4.2 Install Jenkins (LTS)

```bash
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update
sudo apt install -y jenkins
sudo systemctl enable --now jenkins
sudo systemctl status jenkins --no-pager       # should say "active (running)"
```
(Jenkins rotates its signing key from time to time. If `apt update` complains about a signature/key, copy the current
key URL from <https://www.jenkins.io/doc/book/installing/linux/>.)

### 4.3 Let Jenkins use Docker

```bash
sudo usermod -aG docker jenkins
sudo systemctl restart jenkins
sudo -u jenkins docker ps            # must print a table header, NOT "permission denied"
```

### 4.4 First login

1. Browser: `http://<JENKINS_IP>:8080`
2. Get the unlock password on the VM: `sudo cat /var/lib/jenkins/secrets/initialAdminPassword`
3. **Install suggested plugins** → create your admin user → keep the suggested Jenkins URL.
4. **Manage Jenkins → Plugins → Available plugins**: confirm *Pipeline*, *Git*, *GitHub*, *Credentials Binding*, *JUnit*,
   *Timestamper*, *Workspace Cleanup* are installed (most come with "suggested").

### 4.5 Configure tools (names must match the Jenkinsfile exactly)

**Manage Jenkins → Tools**
* **JDK → Add JDK**: Name `JDK21`; untick *Install automatically*; `JAVA_HOME` = `/usr/lib/jvm/java-21-openjdk-amd64`
* **Maven → Add Maven**: Name `Maven3`; untick *Install automatically*; `MAVEN_HOME` = `/usr/share/maven`
* Save.

### 4.6 Add credentials

**Manage Jenkins → Credentials → System → Global credentials (unrestricted) → Add Credentials**

| # | Kind | ID (exact) | Fields |
|---|------|-----------|--------|
| 1 | Username with password | `dockerhub-creds` | Username = Docker Hub username; Password = the **access token** |
| 2 | SSH Username with private key | `app-vm-ssh-key` | Username = `azureuser`; Private Key → *Enter directly* → paste the whole output of `cat ~/.ssh/azure_devops_key` (on your laptop), including the BEGIN/END lines |
| 3 | Secret text | `app-vm-ip` | Secret = `10.0.1.5` (the app VM's **private** IP) |

---

## 5. Set up VM 2: install Kubernetes (one-time, via Ansible from the Jenkins VM)

The Jenkins VM needs the SSH key once, for this manual setup step.

**On your laptop:**
```bash
scp -i ~/.ssh/azure_devops_key ~/.ssh/azure_devops_key azureuser@<JENKINS_IP>:~/azure_devops_key
```

**On the Jenkins VM:**
```bash
chmod 600 ~/azure_devops_key
git clone https://github.com/Amrithseb2006/calculator-devops.git
cd calculator-devops/ansible
cp inventory.ini.example inventory.ini        # already points at 10.0.1.5 with user azureuser

ansible app_servers -m ping --private-key ~/azure_devops_key          # expect: "pong"
ansible-playbook setup-server.yml --private-key ~/azure_devops_key    # installs k3s (~2 min)
```
The last lines print the node as `Ready`. If the clone asks for a password your repo is private; use
`https://<user>:<GitHub-token>@github.com/Amrithseb2006/calculator-devops.git`, or make the repo public.

When done, remove the copy of the key (Jenkins already has it in its credential store):
```bash
shred -u ~/azure_devops_key
```

Quick check on the **app VM** (`ssh -i ~/.ssh/azure_devops_key azureuser@<APP_IP>`):
```bash
sudo k3s kubectl get nodes              # STATUS Ready
sudo k3s kubectl get pods -A            # traefik, coredns, ... Running
```

---

## 6. Create the Jenkins pipeline job and run it

1. Jenkins → **New Item** → name `devops-demo` → **Pipeline** → OK.
2. *Pipeline* section → **Definition: Pipeline script from SCM** → SCM **Git**
   * Repository URL: `https://github.com/Amrithseb2006/calculator-devops.git`
     (private repo → add a GitHub token as a *Username with password* credential and select it)
   * Branch Specifier: `*/main`
   * Script Path: `Jenkinsfile`
3. Save → **Build Now** → open the build → **Console Output**.

Stages: Checkout → Build & Unit Test → Package → Docker Build → Docker Push → **Deploy to Kubernetes on Azure (Ansible)**.
The Jenkinsfile also polls GitHub every 5 minutes, so later pushes trigger builds automatically.

---

## 7. Verify the deployment

From your laptop:
```bash
curl http://<APP_IP>/health            # {"status":"UP"}
curl http://<APP_IP>/                  # version = Jenkins build number
curl "http://<APP_IP>/add?a=40&b=2"    # {"result":42}
```
Or open `http://<APP_IP>/` in a browser.

On the **app VM**:
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml        # lets you use kubectl without sudo
kubectl -n devops-demo get deploy,pods,svc,ingress
kubectl -n devops-demo logs deploy/devops-demo
```
You should see `devops-demo` with `2/2` pods Running.

### Prove the full CI/CD loop
Change the greeting in `App.java`, then:
```bash
git add -A && git commit -m "Change greeting" && git push
```
Jenkins builds → pushes a new image → Ansible applies it → Kubernetes does a rolling update with no downtime.
`curl http://<APP_IP>/` now shows the new build number/message.

---

## 8. Kubernetes things worth demonstrating (on the app VM)

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n devops-demo scale deploy/devops-demo --replicas=4      # scale out
kubectl -n devops-demo get pods -w                                # watch (Ctrl+C to stop)
kubectl -n devops-demo delete pod <one-pod-name>                  # self-healing: a new pod appears
kubectl -n devops-demo rollout history deploy/devops-demo         # revisions (one per build)
kubectl -n devops-demo rollout undo deploy/devops-demo            # manual rollback
kubectl -n devops-demo describe deploy/devops-demo
```
(The next pipeline run sets replicas back to 2, as defined in `k8s/10-deployment.yaml`.)

---

## 9. Optional: GitHub webhook (instant builds instead of 5-minute polling)

GitHub must reach Jenkins on port 8080, but the firewall only allows your IP. Options:
* **Keep polling** (default; nothing to do).
* Or allow GitHub's webhook IP ranges (<https://api.github.com/meta> → `hooks`) on port 8080 in `jenkins-nsg`, then
  GitHub repo → Settings → Webhooks → Add: Payload URL `http://<JENKINS_IP>:8080/github-webhook/`, type `application/json`,
  *push* events; and tick **GitHub hook trigger for GITScm polling** in the job. Don't open 8080 to `0.0.0.0/0`.

## 10. If your Docker Hub repo is private

Create a pull secret on the app VM and reference it in `k8s/10-deployment.yaml`:
```bash
kubectl -n devops-demo create secret docker-registry dockerhub \
  --docker-username=<user> --docker-password=<token>
```
```yaml
    spec:
      imagePullSecrets:
        - name: dockerhub
      containers: ...
```
Simplest for this project: keep the repository public.

## 11. Stop paying / clean up

* **Pause** (stops compute billing; public IPs and disks still cost a little):
  ```bash
  az vm deallocate -g devops-cia-rg -n jenkins-vm
  az vm deallocate -g devops-cia-rg -n app-vm
  az vm start -g devops-cia-rg -n jenkins-vm && az vm start -g devops-cia-rg -n app-vm   # later
  ```
  Public IPs are static, so they stay the same after restart.
* **Delete everything** (VMs, disks, IPs, network):
  ```bash
  az group delete -n devops-cia-rg --yes --no-wait
  ```

## 12. Troubleshooting

| Symptom | Fix |
|---------|-----|
| `SkuNotAvailable` / quota error on `az vm create` | See 3.3: choose another size/region |
| Can't SSH / Jenkins UI times out | Your public IP changed. Update the NSG rules: `az network nsg rule update -g devops-cia-rg --nsg-name jenkins-nsg -n ssh-from-me --source-address-prefixes <new-ip>` (same for `jenkins-ui-from-me`, and `app-nsg`) |
| `Permission denied (publickey)` | Use `-i ~/.ssh/azure_devops_key` and user `azureuser`; `chmod 600` the key |
| `docker: permission denied` in Jenkins | `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins` |
| `Tool type "maven" does not have an install of "Maven3"` / JDK21 | Names in Manage Jenkins → Tools must be exactly `Maven3` and `JDK21` |
| Jenkins fails to start (Java error) | `java -version` must be 21; `sudo journalctl -u jenkins -e` |
| `apt` signature error installing Jenkins | The signing key was rotated; copy the current key URL from jenkins.io install page |
| Ansible `UNREACHABLE` in the pipeline | Credential `app-vm-ip` must be `10.0.1.5`; key in `app-vm-ssh-key` must be the full private key; test `ssh azureuser@10.0.1.5` from the Jenkins VM |
| `kubectl: command not found` in Ansible | `setup-server.yml` was not run on the app VM (section 5) |
| Pods `ImagePullBackOff` | Wrong `DOCKERHUB_USER` in Jenkinsfile, or the Docker Hub repo is private (section 10). `kubectl -n devops-demo describe pod <pod>` |
| Rollout failed, pipeline says "rolled back" | `kubectl -n devops-demo describe pods` and `logs` — usually a crashing app or failing `/health` |
| `curl http://<APP_IP>/` hangs | `app-nsg` must allow port 80; on the VM check `sudo k3s kubectl get pods -A` (traefik must be Running) |
| `404 page not found` from Traefik | Ingress/Service missing: `kubectl -n devops-demo get ingress,svc,endpoints` |
| Jenkins hangs/out of memory | Use ≥ 4 GB RAM, or add swap: `sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile` |
| Deploy stage skipped | It only runs on `main`; check the Branch Specifier is `*/main` |

## 13. Cost notes

Each `B2s` VM costs on the order of one US dollar per day if left running 24×7 (prices vary by region; check the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/)). Deallocate when not in use, and delete the resource group when finished.
