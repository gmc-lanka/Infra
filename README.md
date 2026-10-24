# GMC Lanka – Infrastructure

Infrastructure as code for the [gmc-lanka](https://github.com/gmc-lanka) project: the CI/CD
pipelines, Dockerfiles, the local docker-compose stack and the scripts and settings they use.
The application code lives in [frontend](https://github.com/gmc-lanka/frontend) and
[backend](https://github.com/gmc-lanka/backend); the integration test suites in
[tests](https://github.com/gmc-lanka/tests).

## Layout

```
infra/
├── .github/
│   ├── workflows/
│   │   ├── frontend-ci.yml        Frontend CI/CD (reusable workflow)
│   │   ├── backend-ci.yml         Backend CI/CD (reusable workflow)
│   │   └── tests-ci.yml           CI for the tests repository (reusable workflow)
│   ├── actions/
│   │   └── checkout-sibling/      Checks out another project repo on the matching branch
│   └── dependabot.yml
├── docker/
│   ├── frontend/
│   │   ├── Dockerfile             Node build stage + nginx runtime
│   │   ├── Dockerfile.dockerignore
│   │   └── nginx/default.conf.template
│   └── backend/
│       ├── Dockerfile             Maven build stage + JRE runtime (non-root)
│       └── Dockerfile.dockerignore
├── scripts/
│   ├── coverage-summary.sh        JaCoCo CSV -> Markdown table for the job summary
│   └── deploy-ec2.sh              Pulls and restarts one service on the EC2 host over SSH
├── security/
│   └── backend.trivyignore.yaml   Accepted Trivy findings, each with a reason and expiry date
├── deploy/
│   ├── compose.yaml               Production stack: MySQL, backend, frontend, Caddy (HTTPS)
│   ├── Caddyfile
│   └── .env.example               Server settings (domain, secrets)
└── docker-compose.yml             Whole stack (MySQL, backend, frontend) for local runs
```

## How the pipelines are wired

GitHub only starts workflows that are stored in the repository that was pushed to, so `frontend`,
`backend` and `tests` each keep a short `.github/workflows/ci.yml`. That file holds the triggers,
`concurrency` and permissions, and calls the matching reusable workflow here:

```yaml
jobs:
  pipeline:
    uses: gmc-lanka/infra/.github/workflows/backend-ci.yml@main
    permissions:
      contents: write
      packages: write
    secrets: inherit
```

Inside the reusable workflow, `github.*`, `vars.*` and secrets refer to the calling repository, so image
names (`ghcr.io/gmc-lanka/<repo>`), environments (`staging`, `production`), deploy targets and
release tags stay per repository. Jobs that need more than the service's own code check out:

| Into     | Repository | Used for                                                               |
| -------- | ---------- | ---------------------------------------------------------------------- |
| `.infra` | infra      | Dockerfiles, nginx template, coverage script, Trivy exceptions         |
| `.tests` | tests      | `*IT.java` (backend) and `*.int.test.js` (frontend) integration suites |

`tests` (and, in the tests pipeline, `backend` and `frontend`) are taken from the branch with the same
name as the one being built when it exists, otherwise `develop`, otherwise `main`. So a change that
needs new integration tests can use `feature/42-invoices` in both repositories.

Callers use `@main`, so changes to this repository reach every pipeline once merged to `main`. To try a
pipeline change first, point a caller branch at your infra branch (`...backend-ci.yml@feature/x`) and
pass `with: { infra-ref: feature/x }`.

### Stages

| Stage               | frontend / backend trigger                   | tests trigger     |
| ------------------- | -------------------------------------------- | ----------------- |
| Lint & Format       | Every push and PR                            | Every push and PR |
| Build               | Every push and PR                            | –                 |
| Unit Tests          | Every push and PR (coverage report uploaded) | –                 |
| Integration Tests   | Push to `develop`, PR to `develop`           | Every push and PR |
| Security Scan       | Push to `develop`/`main`, PRs                | –                 |
| Deploy – Staging    | Merge to `develop`                           | –                 |
| Deploy – Production | Merge to `main`, after manual approval       | –                 |

Secrets and variables are still set in each service repository (Settings → Secrets and variables →
Actions, and the `staging` / `production` environments): `CODECOV_TOKEN`, `EC2_HOST`, `EC2_USER`,
`EC2_SSH_KEY` (secrets), `STAGING_URL`, `PRODUCTION_URL` and optionally `DEPLOY_DIR` (variables).
Without `EC2_HOST` a deploy only pushes the image. See [Production on EC2](#production-on-ec2).

## Docker

Images are built from the service repository as build context, with the Dockerfile from here.
From a workspace where the repositories are cloned side by side:

```bash
# Frontend: nginx config comes in through the named build context "nginx"
docker build -f infra/docker/frontend/Dockerfile \
  --build-context nginx=infra/docker/frontend/nginx -t gmc-frontend frontend
docker run --rm -p 8081:80 -e BACKEND_URL=http://host.docker.internal:8080 gmc-frontend

# Backend
docker build -f infra/docker/backend/Dockerfile -t gmc-backend backend
docker run --rm -p 8080:8080 --env-file backend/.env -v gmc-uploads:/app/uploads gmc-backend
```

## Whole stack with docker compose

```bash
cd infra
docker compose up --build     # http://localhost:3000, API on http://localhost:8080
docker compose down           # add -v to also delete the database and uploads
```

Optional settings go in `infra/.env` (`MYSQL_ROOT_PASSWORD`, `FRONTEND_PORT`, `BACKEND_PORT`); backend
settings such as `JWT_SECRET`, mail and Stripe keys are read from `backend/.env` when it exists.

## Production on EC2

`deploy/` runs the whole site on one EC2 instance from the images CI pushes to GHCR, with Caddy in front
for HTTPS. Deploys from CI SSH in and run `docker compose pull <service> && docker compose up -d <service>`
in `~/infra/deploy` (override with the `DEPLOY_DIR` variable).

One-time server setup (Ubuntu, t2/t3.micro):

1. AWS: attach an **Elastic IP**; security group inbound only 22 (your IP), 80 and 443.
2. Docker and 2 GB swap (1 GB RAM is not enough for MySQL + Spring Boot on its own):
   ```bash
   curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $USER   # log out and in
   sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile      && sudo swapon /swapfile && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
   ```
3. Configure and start the stack:
   ```bash
   git clone https://github.com/gmc-lanka/infra.git && cd infra/deploy
   cp .env.example .env && nano .env        # MYSQL_ROOT_PASSWORD, JWT_SECRET, PUBLIC_URL, ...
   docker login ghcr.io -u <github-user>     # token with read:packages (or make the packages public)
   docker compose up -d
   ```
   If the server already ran `docker-compose.yml`, stop that stack first (`docker compose down`, without
   `-v`): this stack reuses its `mysql-data` and `uploads` volumes, so keep the same `MYSQL_ROOT_PASSWORD`.
4. In **backend** and **frontend** → Settings → Environments → `production`: add the secrets `EC2_HOST`
   (Elastic IP), `EC2_USER` (`ubuntu`), `EC2_SSH_KEY` (contents of the instance's `.pem`), the variable
   `PRODUCTION_URL`, and yourself under *Required reviewers* for the manual approval.

Domain: add DNS `A` records for `@` and `www` pointing at the Elastic IP, then in `.env` set
`SITE_ADDRESS=example.lk, www.example.lk`, `PUBLIC_URL=https://example.lk`, `COOKIE_SECURE=true`, run
`docker compose up -d`, and update `PRODUCTION_URL`. Caddy fetches the certificates on its own. Stripe
webhook: `https://example.lk/api/payments/stripe/webhook`.

## Branching and commits

- `main` – what every pipeline uses; protected, changes through PRs
- `feature/<issue>-<slug>`, `fix/<issue>-<slug>`
- Conventional Commits, e.g. `ci(backend): cache Trivy database`
