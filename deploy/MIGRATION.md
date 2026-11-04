# OIDC deployment migration

This change replaces the Auth0 credential broker and SSM-to-shell deployment path with [tc-deploy-scripts v2.0.6](https://github.com/topcoder-platform/tc-deploy-scripts/releases/tag/v2.0.6), fetched by tag and verified against commit `26aaf607463d4a271c0099854c1731214215a9c5`. Build and deployment run in separate jobs. The deployer cannot read Parameter Store, Secrets Manager or decrypt KMS data, including through another assumed role. ECS continues resolving the existing runtime secret references using the execution role.

## Production target

The read-only inventory on 2026-11-03 verified account `409275337247`, cluster `nginx-supply-serverless`, service `nginx-supply-svc`, family `nginx-supply-task`, and container `nginx-supply-container`. `prod.json` preserves the observed task/execution roles and names the proposed service-specific deployment role. [prod-baseline.json](https://github.com/topcoder-platform/v6-services-iac/blob/main/services/docker-nginx-supply/deploy/prod-baseline.json) records references only; it contains no parameter values. Do not recreate the service or replace its complete task definition from this baseline.

## Installed infrastructure and production cutover

The dev deployment role/boundary, restricted empty CircleCI context, and immutable ECR tags are installed. Existing enhanced scanning is preserved. The production OIDC provider, deployment role/boundary and restricted context are also installed; production runtime and ECR changes remain gated on dev validation. Installation evidence and remaining service-specific steps are private in [PROVISIONING.txt](https://github.com/topcoder-platform/v6-services-iac/blob/main/services/docker-nginx-supply/deploy/PROVISIONING.txt). Deploy roles have explicit secret-store and KMS-decryption denies. Runtime values are retrieved only by ECS using the execution role.

At production cutover, stop legacy publishers, enable unconditional tag immutability, adopt missing task health checks with the reviewed image, and use the approval-gated `master` workflow. Preserve capacity, roles, secret references and rollback. Do not run production before dev validation.

## Development acceptance

This PR targets `dev`. Administrator-installed dev prerequisites are recorded in the private IaC repository. The existing revision remains healthy; the first new image and its task probe are promoted atomically after scanning.

Merge to run the dev application deployment, then validate routing and health.

Run the shared offline suite, validate the CircleCI config and IAM policies, and test a dev release plus an unhealthy-image rollback. Verify CloudTrail contains no SSM/Secrets Manager calls from the deployment principal. Remove its old broker grants only after migration. Check the runtime secret references and roles stayed unchanged. Production requires the manual approval job and a passing digest/scan/health verification.

The pinned executor is `cimg/aws@sha256:4cf3768db00ddf9bc439b8c84e8a60c11a14edf81c8baf76f74132144f8340d5`. Python/AWS CLI/Buildx/Git compatibility was tested with the shared offline suite. No package installation or service build runs in the deployment job. The Dockerfile retains the existing in-image quality gates. This PR does not deploy, change IAM, rotate credentials, or claim a successful live rollout.

## Nginx build and public settings

The ECS image is built with `ECSDockerfile`, preserving the patched Ubuntu/nginx base, routing and error pages. Configuration renders inside a clean Docker stage from committed source. Public production CloudFront hostname `d1dpgrdo047sw7.cloudfront.net` and VPC DNS `10.25.0.2` were verified using CloudFront alias metadata and the live task VPC CIDR; no parameter was fetched. Nginx starts as `www-data` and owns only its temporary/cache paths.

The verified dev CloudFront origin is `d10303ypawq4ub.cloudfront.net` and its VPC resolver is `10.15.0.2`. The `dev` Docker target uses those settings; `master` selects the separate `prod` target. Feature branches build dev without deployment credentials. The old image had no curl/wget and was restored after its probe attempt; the new image includes curl, and v2.0.6 adds the task check only when promoting that image.

## Infrastructure source

IAM templates and detailed AWS baselines are maintained in the private [v6-services-iac service directory](https://github.com/topcoder-platform/v6-services-iac/tree/main/services/docker-nginx-supply). Provision infrastructure separately with an administrator identity; application CI does not fetch that repository or install IAM. Required application manifests and health-check proposals remain here.

## Dev branch refresh

This PR targets `dev` and preserves its current application/dependency fixes. The shared suite is v2.0.6 (92 offline tests); service-specific adapters and their tests remain part of review. Use the current readiness record above for the remaining merge/deployment gates. Updating these files does not provision AWS or CircleCI resources.

Source checkout uses the public HTTPS repository and verifies the exact CircleCI commit, avoiding dependency on failing SSH checkout keys. No GitHub token is added to build or deployment contexts.

## Reviewed health-check bootstrap

The release wrapper passes the environment-specific health-check JSON to v2.0.6. A missing check is added with the new scanned image; the old image is not restarted with a new probe. An identical existing check is preserved, and a different existing check stops the release. Role, runtime-secret reference, scan, concurrency and healthy-digest checks remain enforced.

## Environment-specific Nginx build

The `dev` Docker target renders the verified dev CloudFront origin and VPC resolver. The `prod` target retains production settings and is selected only for `master`; feature-branch validation builds dev. The runtime contains curl and bootstraps its reviewed check with the first new image. No AWS credentials or secret parameters are used to render either configuration.
