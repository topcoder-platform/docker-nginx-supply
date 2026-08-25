# Website edge cutover

The website edge migration uses one provider-off Supply release. It removes the
retired website and CMS deployment targets after both DNS views have converged
on CloudFront. It does not retain an in-tree hosting-provider rollback bridge;
rollback is a reviewed Git revert followed by a rebuild and redeployment.

> **Production authority NO-GO:** the checked-in build, snapshot, and deploy jobs set
> `PRODUCTION_AUTHORITY_BOUNDARY_STATUS=BLOCKED_SAME_PROJECT_OIDC`, and each authority
> helper exits before STS. CircleCI issues OIDC tokens to every job, while AWS can restrict
> CircleCI federation by project plus standard audience/subject attributes but cannot use the
> token's job, context, or workflow-approval claims. Roles trusted directly to this same
> project/branch would therefore be reachable before either approval. Do not provision those
> trusts or enable these jobs until one of the external gates below is implemented and
> independently reviewed.

Authority-design references: [CircleCI OIDC token claims](https://circleci.com/docs/guides/permissions-authentication/openid-connect-tokens/)
and [AWS IAM's CircleCI federation condition-key mapping](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html#condition-keys-wif).

## Commit identity

Record the immutable commit and image identifiers for the candidate. A branch
that *contains* a reviewed commit is not proof that the reviewed commit is its
actual head. Resolve and compare the head directly:

```shell
CUTOVER_SHA="$(git rev-parse contentful_migration^{commit})"
test "$(git rev-parse contentful_migration^{commit})" = "$CUTOVER_SHA"
```

`git branch --contains` and `git tag --contains` answer only the containment
question; they do not identify a ref's actual head. Approve and deploy the
actual `CIRCLE_SHA1` checked out by the production job, and bind the recorded
image ID/digest to that SHA. If the merge strategy rewrites either candidate
(for example, a squash), treat the new master head as a new candidate and
repeat the complete validation. Never infer equivalence merely because a ref
contains the reviewed commit.

The checked-in `master` workflow is a fail-closed artifact/release rehearsal. Its
no-authority `prepare-prod-tooling` job first creates a private virtual
environment from a hash-locked dependency file and checks out the exact reviewed
deployment-suite commit. It verifies and applies the repository-owned immutable-tag retry
patch, then persists the patched helper and its base task-definition template with their
hashes. It also downloads the exact CircleCI CLI v1.0.48692 archive over verified TLS,
checks the committed archive and extracted-binary SHA-256 values, compiles the 2.1 config,
and syntax-checks every processed Bash command. Its intended sequence places `approve-prod`
before a read-only production build.
After a genuine external authority gate is added, the non-deploying `build-prod` job labels
the image with
the exact `CIRCLE_SHA1` and persists one workspace artifact bound to that source SHA,
Docker image ID, actual archive config digest, Docker server version, archive checksum, and
the complete provider-off route-verification evidence.

The separate `verify-prod` job receives no AWS context. It reloads the approved image,
rechecks every identity, runs `nginx -t`, executes the Community fallback and
retired-provider route contracts, and exercises the full PID-1 runtime using its required
writable-root contract. A
read-only `snapshot-prod-deployvars` job is intended to record exact version, ARN, and
last-modified
metadata for all present deploy variables plus explicit absent-optional markers; it persists
no decrypted values. The second hold, `approve-prod-deploy`, depends on that snapshot. After
an external gate makes that hold enforceable, `deploy-prod` does not rebuild the image or
rerun build/route-test
scripts: before assuming the role it rechecks the complete artifact, tooling, template,
and verification evidence and runs `nginx -t` against the loaded image. After assumption,
the only repository helpers it executes are the reviewed deploy-role setup and safe SSM
loader; deployment itself uses the persisted hash-verified helper.

The deploy invocation uses one project-scoped `production-ecs` serial group. CircleCI
therefore permits only one production ECS mutation at a time across workflows and skips an
older pipeline that attempts to join while a newer pipeline is queued or running. The lock
wait is limited to five hours; a timeout or skip requires a fresh review rather than a
manual bypass. An older workflow rerun can still start when the serial group is otherwise
empty, so rollback remains an explicit, recorded operator action.

With short-lived deployment authority, the job safely imports an explicit
deployment-variable allowlist, rejects configurable ECS task roles, validates the current
cluster/services/runtime-parameter references/log group, and requires the existing ECR
repository to be `IMMUTABLE`. It tags the approved image with the source SHA. When that
immutable tag is absent, the pinned helper pushes it; when a retry finds the tag already
bound to the exact approved config digest, the reviewed patch skips only that push. Any
other tag state fails closed. After the helper runs, the job rechecks the remote digest and
immutability, waits for ECS stability, and requires each service to have one completed
deployment with `desiredCount > 0`, no pending tasks, and all desired tasks running. It
also verifies a new task-definition revision, the exact immutable image, one Supply
container and no sidecars, no task role, the forced Supply execution role, the exact
normalized ports and approved/defaulted container/task CPU and memory, the sole reviewed
EFS volume/mount, non-privileged Fargate configuration, and empty command, health,
environment, and secret arrays. The
registry digest, prior/new task-definition ARNs, and runtime-reference evidence are stored
in a non-secret deployment manifest.

Before the first approval, verify the pending workflow's `CIRCLE_SHA1` against
the reviewed release head. Before the second approval, verify the completed
build's source SHA, image ID, checksum, route-contract output, deploy-variable
version manifest, and manifest checksum. If its
workspace has expired or any identity check fails, start a new workflow and
review its new artifact; never reconstruct or substitute an image after the
deployment approval.

### Required production authority boundary

Provision and independently review all of these controls before the release is eligible
to run. Their absence is an intentional failing precondition. In particular, a restricted
or empty CircleCI context is not an AWS-enforced job/approval boundary because the OIDC token
exists independently of context contents.

- Select and implement one independently enforced authority gate: a separate, locked
  CircleCI release project whose distinct project ID is trusted by AWS and whose artifact
  handoff/trigger is approval-bound; a credential broker that validates the signed token's
  job/workflow/context claims and confirms the required CircleCI approval before issuing a
  role session; or an external deployment orchestrator/manual SSO release that consumes the
  exact approved artifact. Record the threat model, real identity IDs, trust/broker policy,
  approval evidence, retry behavior, and revocation path.
- Do **not** create roles that trust the current Docker Supply CircleCI project directly.
  Project ID plus V2 repository/branch subject restrictions are useful source boundaries but
  cannot distinguish `prepare-prod-tooling`, `verify-prod`, or a post-approval authority job.
  Custom CircleCI job/context/workflow claims are present in the token but are not supported
  AWS IAM CircleCI condition keys. Any job in this project could otherwise call STS before a
  hold. The three context names in the checked-in workflow and the direct-OIDC helper scripts
  are staged implementation inputs, not an approved authority design.
- Keep `PRODUCTION_AUTHORITY_BOUNDARY_STATUS=BLOCKED_SAME_PROJECT_OIDC` committed until the
  chosen external gate is implemented. The eventual gated executor may change it to
  `VERIFIED_EXTERNAL_AUTHORITY_GATE` only as part of a separately reviewed integration that
  proves the current project itself still cannot assume any production role. Do not attach
  `org-global`, static AWS credentials, profiles, or credential-file overrides as a bypass.
- After that boundary exists, preserve separate build, deploy-variable snapshot, and deploy
  roles. The build role may use only `ssm:GetParameters` for the exact production build
  parameters and
  `kms:Decrypt` on the dedicated key, constrained by `kms:CallerAccount`,
  `kms:ViaService=ssm.us-east-1.amazonaws.com`, and each exact
  `kms:EncryptionContext:PARAMETER_ARN`. The job adds an inline 900-second session policy
  with the same exact resources. The provider-off build requests only
  `ENV_PLATFORM_UI_RESOLVER`, which must be a `SecureString` encrypted by that key. The
  retired origin parameter is not authorized, requested, rendered, or included in the
  approval manifest.
- The snapshot role may use `ssm:GetParameters` for only the exact 12 deploy-variable ARNs.
  It does not request decryption and must have no KMS, ECR, ECS, IAM, SSM write, or path-list
  authority. Its compact STS session policy is a 183-character path-scoped ceiling; the
  exact-name role policy is the other half of the permission intersection. An offline
  regression test enforces AWS STS's 2,048-character session-policy limit. Do not broaden the
  role policy to the session wildcard.
- Give the deploy role only the exact read/decrypt, immutable-ECR push/inspect,
  task-definition registration, existing-service update/describe, and log-group inspection
  permissions required by the reviewed production configuration. Scope ECR access to the
  exact repository; ECS access to the exact cluster, services, and task family; and
  `iam:PassRole` to only
  `arn:aws:iam::409275337247:role/ecsTaskExecutionRole` with
  `iam:PassedToService=ecs-tasks.amazonaws.com`. The unavoidable resource-wide reads are
  ECR authorization, ECS task-definition description, and log-group description. Explicitly
  deny repository mutation/deletion, repository/service/cluster/log-group creation, and
  destructive ECS/ECR actions. Confirm the empty appvar path, ECR repository, cluster,
  services, execution role, and log group as concrete reviewed resources before approval;
  an account-wide deployment policy is not an acceptable substitute.
- Permit deploy-variable `ssm:GetParameters` only for the 12 names the job loads: the eight
  required repository/cluster/service/family/container/ports/read-only-root/EFS values and
  the four optional CPU/memory values. For this release,
  `AWS_ECS_READONLY_ROOTFILESYSTEM` must be exactly `false`: the legacy nginx package and
  entrypoint require writable runtime paths, and the pinned deploy helper otherwise defaults
  the task definition to read-only. The job verifies the deployed container definition is
  also `false`. Treat this as a reviewed temporary constraint, not a claim that read-only
  operation has been achieved. `AWS_ECS_VOLUMES`, `AWS_ECS_CONTAINER_HEALTH_CMD`, and
  `AWS_ECS_CONTAINER_CMD` are not approved inputs and must be absent from SSM and the job
  environment. The job exports exact empty values for those fields only for compatibility
  with the pinned helper. `AWS_ECS_VOLUMES_EFS` is instead a required compatibility input:
  it must describe exactly one whitespace-free mapping, match the separately reviewed
  repository SHA-256, and mount at `/data/nginx`. The job verifies that mapping is the task's
  sole volume and sole writable mount, with no transit-encryption or EFS IAM-authorization
  settings silently added. It also verifies no command or entrypoint override, container
  health command, plain environment, or secrets. The optional container memory reservation,
  container CPU, Fargate CPU, and Fargate memory inputs use the pinned helper's defaults of
  `1000`, `100`, `1024`, and `2048` when absent. Before deployment the job normalizes the
  exact reviewed port mappings and effective resource values; afterward it requires one
  total container and exact equality for all of them. Permit decrypt only
  through SSM and only for those exact parameter encryption contexts on a dedicated
  deploy-variable CMK. Do not grant either ECS task-role parameter to the job; inherited
  `AWS_ECS_TASK_ROLE_ARN` or `AWS_ECS_TASK_EXECUTION_ROLE_ARN` values fail closed.
- Permit metadata-only, non-recursive `ssm:GetParametersByPath` on
  `/config/docker-nginx-supply/appvar/` solely to prove the path is empty. Supply has no
  approved runtime appvars, the helper receives no `-j` path, and the deployed secret and
  plain-environment arrays must be empty. The reviewed Supply-only `ecsTaskExecutionRole`
  therefore needs exact ECR pull and log-stream permissions but no runtime SSM/KMS access.
  It must trust only `ecs-tasks.amazonaws.com`; a broad shared execution role is a release
  blocker.
- Confirm every allowlisted `/config/docker-nginx-supply/deployvar` input is a
  `SecureString`. The loader requests only exact names, rejects missing required names,
  non-SecureString or duplicate/unexpected responses, and pre-set allowlisted variables,
  and never evaluates a parameter value as shell. Compare all 12 values with a separately
  approved production inventory before approval: IAM cannot constrain the container name,
  ports, read-only flag, EFS mapping, or CPU/memory values. The three removed runtime-override
  names are deliberately outside the loader allowlist. The
  pre-approval job snapshots version/ARN/last-modified metadata from non-decrypted exact-name
  responses. Deployment requests `name:version` selectors with decryption and fails
  on a missing version, metadata mismatch, newly present optional value, or response drift.
- Before `approve-prod-deploy`, record the exact name, version, type, and approved value hash
  for every present deploy variable; record explicit absence evidence for each absent optional
  name. Then enforce a write/delete freeze on all 12 exact parameter ARNs from the start of
  review until deployment and post-deploy verification complete. The
  freeze must be enforced outside the deploy session (for example with an IAM/SCP deny whose
  break-glass path is separately controlled), and the reviewer must retain the policy and
  version inventory as release evidence. Any write, deletion, new version, missing version
  evidence, or lifted freeze invalidates the approval and requires a new workflow. The job
  loads present values at their snapshotted versions only after the second hold and performs
  unversioned negative checks for approved-absent optional names. Exact selectors close
  ordinary latest-version drift, while the external freeze and audit remain mandatory to
  cover deletion/recreation, newly appearing optional values, and break-glass activity that
  repository code cannot exclude.
- Confirm the target ECR repository already exists with `imageTagMutability=IMMUTABLE`.
  The deployment fails before the helper if it is absent or mutable and rechecks the same
  property afterward; the helper's create-repository path is not authorized. Preserve the
  repository-owned helper patch and all three reviewed hashes. A retry may skip the push
  only when `BatchGetImage` proves the existing source-SHA tag has the exact approved
  config digest.
- Preprovision `/aws/ecs/<exact-cluster>` with reviewed encryption and retention. Before
  deployment, require the exact cluster and services to be active and stable, all current
  task definitions to use the approved family, and record every previous task-definition
  ARN. Afterward, independently verify the service counts/deployment state and task
definition as described above, including `readonlyRootFilesystem=false`; the helper's event-text polling alone is not release
  evidence.

The committed `EXPECTED_AWS_ECS_VOLUMES_EFS_SHA256=INVENTORY_REQUIRED` value is an explicit
NO-GO for this release. Before replacing it, a named operator must inventory the exact
production, development, and QA EFS mappings without disclosing their values; review the
volume name, root directory, `/data/nginx` mount, filesystem ID, security groups, mount
targets, and NFS reachability; and prove the mounted retained content serves every Supply
route that still reads `/data/nginx/apache_docs/tcdocs`. Scan that content for retired
provider URLs as well as secrets, record its approved hash/evidence, and commit only the
mapping SHA-256 expected by each environment. A missing mount target, content mismatch,
retired-provider reference, or sentinel left in place is a release NO-GO.

The production jobs pin the Circle executor by digest, use the Gen2 executor class, and pin
remote Docker 28. The repository pins and hash-verifies the CircleCI CLI used to validate and
compile the 2.1 config; the regression suite syntax-checks the compiled commands so escaped
Bash here-strings cannot silently become invalid jobs. A separate executable regression
extracts the embedded production task-definition jq assertion itself, accepts the exact
two-port fixture, and rejects sidecar, port, resource, secret, and EFS drift. The build
records the actual config object found in either supported classic or containerd Docker
archive layout, rather than assuming Docker's inspect ID is
always that config digest. The runtime image copies no files from `scripts/`; CI credentials,
deploy helpers, tooling, tests, provider fixtures, and the retired cron/HUP reload mechanism
remain outside the image. The entrypoint fails on `nginx -t` errors and then replaces itself
with nginx. After each build/load, the provider-off image verifier scans image metadata,
the extracted application tree, and the running container's expanded `nginx -T` output;
the runtime contract also exercises all fail-closed website paths over HTTP. The task must
use the explicitly reviewed writable-root setting described above;
the release does not depend on a Docker-only tmpfs mount. The variable-based Community
fallback upstream uses nginx's configured resolver and refreshes DNS at runtime.
Literal-host `proxy_pass` directives elsewhere
in this legacy configuration remain start/reload-bound; accept and monitor that limitation for
this cutover, then either convert those upstreams or add a supported reload mechanism in a
separately reviewed change. The removed cron helper was not installed or running in the image.

Production is also blocked until the image-base decision is closed. The current candidate
pins an Ubuntu Focal digest even though Focal standard security maintenance has ended, and
the custom `nginx-topcoder-full=1.18.0-1Topcoder1` package has no demonstrated supported-base
or ESM update path in this repository. The Dockerfile installs all updates still published
by the public Focal archive (the local rehearsal had zero public upgrades pending), but
that is not future security coverage. Before the release, migrate and rebuild on a
supported compatible base (preferred), including rebuilding the Topcoder nginx package, or
use a formally maintained third-party package with its own documented patch SLA. Ubuntu
Pro/ESM coverage for the base alone does not cover the PPA package. Then run an authenticated
registry vulnerability scan and resolve all release-policy findings. The base digest pins
the starting layer and the recorded artifact identities bind the built output; mutable
APT/PPA resolution means it does not make a future rebuild reproducible.

Dev and QA must also stop using generated SSM shell files and the shared legacy parameter
namespace. Their jobs now use the same non-evaluating exact-name loader as production and
dedicated CircleCI contexts. The interim credential-broker client constructs JSON without
shell evaluation, requires verified HTTPS, rejects inherited AWS providers and endpoint
overrides, stores credentials in a task-owned random directory, verifies the broker claim,
account, environment, region, and exact STS assumed-role name, and deletes that directory
after deployment.

| Environment | Dedicated context | Repo-owned account | Exact broker role name | SSM root | Eligibility |
| --- | --- | --- | --- | --- | --- |
| DEV | `docker-nginx-supply-dev-deploy` | `811668436784` | `circleci-docker-nginx-supply-dev-deploy` | `/config/docker-nginx-supply/dev` | **NO-GO** until the context/role is provisioned and all three roots are migrated and inventoried |
| QA | `docker-nginx-supply-qa-deploy` | `INVENTORY_REQUIRED` | `circleci-docker-nginx-supply-qa-deploy` | `/config/docker-nginx-supply/qa` | **NO-GO**; a named operator must first record the broker STS account and actual SSM/ECS inventory, then replace the sentinel in a reviewed commit |

For each environment, migrate exact `buildvar`, `deployvar`, and `appvar` values beneath the
listed root, update the dedicated role to only those paths and existing release resources,
and prove the old and new inventories match before enabling its branch. Build/deploy/app
parameters must be `SecureString` where the corresponding loader or runtime contract requires
it. Independently confirm the exact EFS mapping and hash after migration. Missing context
restrictions, an unprovisioned exact role, the QA account or EFS hash sentinel, an inventory
mismatch, or missing type conversion is a deliberate pipeline NO-GO.
The interim context is still job-wide, so its long-lived Auth0 client secret is available to
checkout and mutable dependency/tooling setup as well as authentication. That is a remaining
supply-chain exposure: keep these non-production jobs in NO-GO state until they either use
an external broker/policy that can distinguish the authorized deploy stage, or split a
no-authority, exact-artifact build from a separately gated deploy job. Replacing the long-lived
secret with same-job direct OIDC would improve credential lifetime but would not close the
authority gap because that token also exists from job start. Dedicated contexts and the safer
client reduce accidental exposure but do not make the current combined jobs eligible.

The build uses pinned AWS CLI v1 because deployment-suite v1.4.18 still requires its legacy
ECR login command. Production does not use that suite's legacy Auth0 credential helper.
AWS CLI v1 entered maintenance mode on 2026-07-15 and reaches end of support on 2027-07-15.
Replace the ECR login path and move this pipeline to a pinned, verified AWS CLI v2 installer
as a separately owned, time-bounded follow-up.

## Provider-off routing contract

Apply the public and private Route 53 changes and wait until both change IDs
report `INSYNC`. Start the hold from the later of those two `INSYNC`
timestamps. Wait a full 3,630 seconds before merging or approving the release: the
3,600-second private `www` ALB record TTL must expire, plus a 30-second safety
margin. One successful normal-DNS probe is not evidence that every resolver
cache has converged.

The provider-off release makes unmatched website routes and the unverified `/api/` remainder
fail closed at Supply. It preserves exact and descendant fallbacks for the
verified Community App API families `/api/cdn`, `/api/recruit`, `/api/mml`, and
`/api/feeds`. Normal API traffic must continue to use the ALB `/api*` listener
rule. `/api/blog` and `/api/gsheets` remain deliberately fail closed because
Community App has no verified routers for them. The replacement website
runtime API remains `/__api` at CloudFront.

The public website default, generated pages, fonts, former mini-sites, the six website-owned
AI Hub route families, and `/marathon-match-tournament/schedule` are then served from the
private S3 origin behind CloudFront; Supply has no special override for those paths. The release
removes the old hosting/CMS proxy include, substitution,
and route overrides; its source and rendered deployment inputs are scanned for
retired hosting, CMS, asset, and proxy targets. The focused
contract is:

```shell
./scripts/test-retired-provider-routes.sh
```

## Rollback

Revert the provider-off commit in Git, rebuild the reverted source, run its full route and
image verification suite, and deploy that immutable image. The provider-off branch retains
no live bridge or alternate origin. If rollback also changes either DNS view, verify the
reverted image and its restored route dependencies before changing DNS, wait for both Route
53 changes to report `INSYNC`, and hold the reverted image for at least 3,630 seconds from
the later `INSYNC` timestamp. Never point DNS back at the ALB while the provider-off image
is still running there.
