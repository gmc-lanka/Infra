# GMC Lanka – Infrastructure

Infrastructure as code for the [test-gmc-lanka](https://github.com/test-gmc-lanka) project: the CI/CD
pipelines, Dockerfiles, the local docker-compose stack and the scripts and settings they use.
The application code lives in [frontend](https://github.com/test-gmc-lanka/frontend) and
[backend](https://github.com/test-gmc-lanka/backend); the integration test suites in
[tests](https://github.com/test-gmc-lanka/tests).

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
│   └── coverage-summary.sh        JaCoCo CSV -> Markdown table for the job summary
├── security/
│   └── backend.trivyignore.yaml   Accepted Trivy findings, each with a reason and expiry date
└── docker-compose.yml             Whole stack (MySQL, backend, frontend) for local runs
```

## How the pipelines are wired

GitHub only starts workflows that are stored in the repository that was pushed to, so `frontend`,
`backend` and `tests` each keep a short `.github/workflows/ci.yml`. That file holds the triggers,
`concurrency` and permissions, and calls the matching reusable workflow here:

```yaml
jobs:
  pipeline:
    uses: test-gmc-lanka/infra/.github/workflows/backend-ci.yml@main
    permissions:
      contents: write
      packages: write
    secrets: inherit
```

Inside the reusable workflow, `github.*`, `vars.*` and secrets refer to the calling repository, so image
names (`ghcr.io/test-gmc-lanka/<repo>`), environments (`staging`, `production`), deploy hooks and
release tags stay per repository. Jobs that need more than the service's own code check out:

| Into     | Repository | Used for                                                                 |
| -------- | ---------- | ------------------------------------------------------------------------ |
| `.infra` | infra      | Dockerfiles, nginx template, coverage script, Trivy exceptions           |
| `.tests` | tests      | `*IT.java` (backend) and `*.int.test.js` (frontend) integration suites   |

`tests` (and, in the tests pipeline, `backend` and `frontend`) are taken from the branch with the same
name as the one being built when it exists, otherwise `develop`, otherwise `main`. So a change that
needs new integration tests can use `feature/42-invoices` in both repositories.

Callers use `@main`, so changes to this repository reach every pipeline once merged to `main`. To try a
pipeline change first, point a caller branch at your infra branch (`...backend-ci.yml@feature/x`) and
pass `with: { infra-ref: feature/x }`.

### Stages

| Stage               | frontend / backend trigger                   | tests trigger    |
| ------------------- | -------------------------------------------- | ---------------- |
| Lint & Format       | Every push and PR                            | Every push and PR |
| Build               | Every push and PR                            | –                |
| Unit Tests          | Every push and PR (coverage report uploaded) | –                |
| Integration Tests   | Push to `develop`, PR to `develop`           | Every push and PR |
| Security Scan       | Push to `develop`/`main`, PRs                | –                |
| Deploy – Staging    | Merge to `develop`                           | –                |
| Deploy – Production | Merge to `main`, after manual approval       | –                |

Secrets and variables are still set in each service repository (Settings → Secrets and variables →
Actions, and the `staging` / `production` environments): `CODECOV_TOKEN`, `STAGING_DEPLOY_HOOK`,
`PRODUCTION_DEPLOY_HOOK`, `STAGING_URL`, `PRODUCTION_URL`.

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

## Branching and commits

- `main` – what every pipeline uses; protected, changes through PRs
- `feature/<issue>-<slug>`, `fix/<issue>-<slug>`
- Conventional Commits, e.g. `ci(backend): cache Trivy database`
