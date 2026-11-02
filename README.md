# devops-demo: CI/CD on Azure (Git → Jenkins → Maven → Docker → Ansible → Kubernetes)

A small Java web service plus everything needed to build, test, containerise and deploy it to **Kubernetes on Azure**
every time you push code. Jenkins and the application each run on their own Azure VM (2 VMs in total).

> **Full step-by-step deployment instructions: see [AZURE-DEPLOYMENT.md](AZURE-DEPLOYMENT.md).**

## Architecture

```
 Developer ──git push──▶ GitHub ──poll/webhook──▶ Jenkins (Azure VM 1)
                                                    │ 1 Checkout        (Git)
                                                    │ 2 Build + test    (Maven, JUnit)
                                                    │ 3 Package         (jar)
                                                    │ 4 Docker build
                                                    │ 5 Docker push ───────▶ Docker Hub
                                                    │ 6 ansible-playbook (SSH over the Azure VNet)
                                                    ▼
                                        App VM (Azure VM 2) running k3s (Kubernetes)
                                        Deployment (2 pods) ─ Service ─ Ingress (Traefik :80)
                                                    └──▶ http://<APP_VM_PUBLIC_IP>/health
```

| Tool | Role |
|------|------|
| Git / GitHub | Source control; triggers the pipeline |
| Maven | Compiles, runs JUnit tests, builds `target/devops-demo.jar` |
| Docker / Docker Hub | Packages the jar into an image and publishes it |
| Jenkins | Orchestrates every stage (`Jenkinsfile`) |
| Ansible | Installs k3s on the app VM; applies the Kubernetes manifests on every build |
| Kubernetes (k3s) | Runs the app: 2 replicas, health probes, rolling updates, auto-rollback |
| Azure | 2 Ubuntu VMs, VNet, network security groups (`azure/provision.sh`) |

## Layout

```
├── pom.xml                         Maven build (Java 17 target, JUnit 5)
├── src/main/java/com/devops/       App.java (JDK HTTP server), Calculator.java
├── src/test/java/com/devops/       Unit + endpoint tests
├── Dockerfile                      Runtime image (jre-alpine, non-root, healthcheck)
├── Jenkinsfile                     The pipeline
├── k8s/                            Namespace, Deployment, Service, Ingress
├── ansible/                        setup-server.yml (install k3s), deploy.yml (kubectl apply + rollout)
├── azure/provision.sh              Creates the Azure VMs, network and firewalls
└── AZURE-DEPLOYMENT.md             Complete deployment guide
```

## Endpoints

| Path | Example response |
|------|------------------|
| `GET /` | `{"app":"devops-demo","version":"<build#>","message":"..."}` |
| `GET /health` | `{"status":"UP"}` |
| `GET /add?a=2&b=3` | `{"result":5}` |
| `GET /multiply?a=3&b=4` | `{"result":12}` |
| `GET /divide?a=10&b=4` | `{"result":2.5}` (400 on divide by zero) |

## Run locally

```bash
mvn clean package
java -jar target/devops-demo.jar
curl localhost:8080/health
```

## Pipeline stages

| Stage | Action | Fails when… |
|-------|--------|-------------|
| Checkout | `checkout scm` | Repo/credentials wrong |
| Build & Unit Test | `mvn clean verify` + JUnit report | Compile error / failing test |
| Package | `mvn package`, archive jar | Build problem |
| Docker Build | `docker build -t user/devops-demo:<build#>` | `jenkins` user not in `docker` group |
| Docker Push | `docker login` + `docker push` | Bad Docker Hub token |
| Deploy to Kubernetes | `ansible-playbook deploy.yml` → `kubectl apply`, wait for rollout, rollback on failure | SSH/NSG problem, k3s not installed, bad image |

Deploy runs only for the `main` branch.
