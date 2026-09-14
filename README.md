# eEarly Mobile Module Keycloak

This repository contains Jenkinsfiles and configuration to build and upload the Mobile Keycloak artifact to Nexus.

It packages a [Keycloak](https://www.keycloak.org/) image pre-loaded with the `eearly-mobile` realm
(`realm-config/eearly-mobile-realm.json`) and its clients: `eearly-mobile`, `eearly-backoffice`,
`admin-service`, `eearly-user-administrator`, …

---

## Prerequisites

| Requirement | Version / note |
|-------------|----------------|
| Docker | to build and run the image; Docker Compose is optional |

No Java/Maven toolchain is needed — the image is built directly from the upstream Keycloak base image.

## Run locally

### 1. Build the image

```bash
docker build -t eearly-mobile-keycloak .
```

This runs `kc.sh build` with the realm baked in, matching what Jenkins ships to Nexus/production.

### 2. Start a Postgres database for Keycloak

```bash
docker network create eearly-mobile-keycloak-net

docker run -d --name eearly-mobile-keycloak-db \
  --network eearly-mobile-keycloak-net \
  -e POSTGRES_DB=keycloak \
  -e POSTGRES_USER=keycloak \
  -e POSTGRES_PASSWORD=keycloak \
  -p 5435:5432 \
  postgres:17
```

### 3. Run Keycloak

```bash
docker run -d --name eearly-mobile-keycloak \
  --network eearly-mobile-keycloak-net \
  -e KEYCLOAK_ADMIN=admin \
  -e KEYCLOAK_ADMIN_PASSWORD=admin \
  -e KC_DB=postgres \
  -e KC_DB_URL=jdbc:postgresql://eearly-mobile-keycloak-db:5432/keycloak \
  -e KC_DB_USERNAME=keycloak \
  -e KC_DB_PASSWORD=keycloak \
  -e KC_HOSTNAME=localhost \
  -e KC_HTTP_ENABLED=true \
  -p 9091:8080 \
  -p 9190:9000 \
  eearly-mobile-keycloak \
  start --optimized --import-realm
```

Host port `9091` is used so this matches the `MOBILE_KEYCLOAK_BASE_URL` /
`http://localhost:9091` convention expected by
[eearly-admin-module-service](https://github.com/e-early/eearly-admin-module-service.git) and
[eearly-mobile-module-service](https://github.com/e-early/eearly-mobile-module-service.git) when
they are run locally against this Keycloak.

### 4. Verify

- Admin console: http://localhost:9091 (log in with `admin` / `admin`, as set above)
- Health: http://localhost:9190/health/ready
- **Realm settings → eearly-mobile** should already exist, imported from `realm-config/eearly-mobile-realm.json`
- **Clients** should list `eearly-mobile`, `eearly-backoffice`, `admin-service`, `eearly-user-administrator`, etc. —
  open a client's **Credentials** tab to fetch the secret needed by consuming services
  (e.g. `MOBILE_KEYCLOAK_ADMIN_CLIENT_SECRET` / `KEYCLOAK_ADMIN_CLIENT_SECRET`)

### 5. Stop / clean up

```bash
docker rm -f eearly-mobile-keycloak eearly-mobile-keycloak-db
docker network rm eearly-mobile-keycloak-net
```

---

## Releasing

This repository uses a lightweight git-flow release helper. It only updates `version.json` and git state; it does not
run a local Keycloak build. Jenkins builds and deploys the Docker image from the release branch.

Start a release from an up-to-date `development` branch:

```bash
bash release.sh start
```

The start command asks for the release version, defaulting to `version.json` with `-SNAPSHOT` removed. It creates
`release/<version>`, sets `version.json` to the release version on that branch, bumps `development` to the next patch
snapshot version automatically, and pushes both branches. It fails if any local `release/*` branch already exists.

After Jenkins succeeds, finish the release from `development`:

```bash
bash release.sh finish
```

The finish command requires exactly one local `release/*` branch. It merges that branch into `master`, creates an
annotated tag named after the release version, deletes the local and remote release branch, and returns to
`development`.
