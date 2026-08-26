# docker-nginx-supply

Docker image for testing and deployment of the Supply nginx pipeline.

## Website edge release

The provider-off website edge release, approval gate, DNS convergence hold, and
Git-revert rollback are documented in [docs/website-edge-cutover.md](docs/website-edge-cutover.md).
Production authority is intentionally blocked: all three authority jobs carry
`BLOCKED_SAME_PROJECT_OIDC` and their helpers exit before STS. CircleCI approvals and empty
contexts cannot distinguish AWS access between jobs in one project. Do not provision direct
OIDC trusts for this project; first implement the separate release project, approval-aware
credential broker, or external release orchestrator described in the cutover document.

After that external gate exists, the intended workflow has separate build and deploy
approvals. The approved build persists a
source-SHA/archive-checksum/image-ID/config-digest-bound workspace image; the separately
approved deployment job only loads that artifact, publishes it under an immutable source-SHA
tag, and verifies the reviewed ECS service/task-definition/runtime-parameter identity. A
no-AWS verification job runs the route contracts between the gated authority stages.
A dedicated read-only job then snapshots deploy-variable version or absence evidence; the
second approval reviews that metadata, and deployment loads against that exact approval.
Present values are requested at their approved versions; explicitly absent optional names are
rechecked unversioned and must remain absent.
Production ECS mutations share one project-level serial group, preventing concurrent
workflow deploys and rejecting an older pipeline when it attempts to join while a newer
pipeline is queued or running. An older rerun can still start when the group is empty.
Production also remains blocked until the dedicated KMS keys, immutable ECR repository,
stable preprovisioned ECS services, exact Supply-only task execution role, and vulnerability
scan gate described in the cutover document are complete. The eventual gated deployment job
requires an exact least-privilege deploy role; it rejects inherited AWS credential providers
and configurable ECS task roles, and it does not use the legacy Auth0 helper.
The current release contract requires the exact deploy variable
`AWS_ECS_READONLY_ROOTFILESYSTEM=false` and verifies the resulting task definition. This is
an explicit compatibility constraint for nginx's writable runtime paths, not completed
read-only root support. Host-volume, task command/entrypoint and container-health overrides,
plain environment, and runtime appvar secrets are all forbidden and verified absent. One
legacy-content EFS mapping is required, must match a repository-reviewed SHA-256, and is
verified as the task's sole volume and sole mount at `/data/nginx`. Its committed hash is
deliberately `INVENTORY_REQUIRED`, so every environment remains fail closed until a named
operator reviews the exact mapping and mounted content. Post-deployment checks also require
one total container, the exact reviewed port
mappings, and the exact effective container/Fargate CPU and memory values (including helper
defaults when optional inputs are absent).
The runtime image contains no CI/deploy/test scripts and no cron-based nginx reload helper;
its entrypoint validates the configuration and then runs nginx directly. The provider-off
release scans image metadata, extracted application inputs, and expanded running nginx
configuration after every build/load, and probes all fail-closed routes over HTTP.
The production image pins the reviewed Ubuntu Noble official-image digest and installs only
Ubuntu's `nginx` and `ca-certificates` runtime packages. The custom Topcoder nginx package,
its PPA, and its otherwise-unused AJP buffer directive have been removed; source regression
tests reject any `ajp_pass` or AJP buffer directive.
The Community App fallback uses `ENV_PLATFORM_UI_RESOLVER` as its Fargate VPC
DNS resolver. Supply validates that value as IPv4 and renders it into nginx.
Production tooling pins and hash-verifies
the CircleCI CLI, compiles the 2.1 configuration, and syntax-checks its processed Bash. The
unrelated Platform UI origin and route changes are not required by this release.

To build the docker image:

```shell
docker build -t appiriodevops/nginx-supply:latest .
```

To run the docker container:

```shell
docker build -d -e "ENV=<ENVIRONMENT>" -P 8000:8000 appiriodevops/nginx-supply
```

The build script creates the configurations for dev and builds the docker image. Run runs it.
