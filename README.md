# eEarly Mobile Module Keycloak

This repository contains Jenkinsfiles and configuration to build and upload the Mobile Keycloak artifact to Nexus.

# eEarly EHR Module Keycloak

This repository contains Jenkinsfiles and configuration to build and upload the EHR Keycloak artifact to Nexus.

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
