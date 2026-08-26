#!/usr/bin/env python3
"""Verify the resolved production build/approval/deploy authority contract."""

from __future__ import annotations

import sys
import re
from pathlib import Path
from typing import Any

try:
    import yaml
except ModuleNotFoundError as error:  # pragma: no cover - operator dependency guard
    raise SystemExit("PyYAML is required to verify the resolved CircleCI config.") from error


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = (
    Path(sys.argv[1]).resolve()
    if len(sys.argv) == 2
    else REPOSITORY_ROOT / ".circleci" / "config.yml"
)
if len(sys.argv) > 2:
    raise SystemExit("Usage: test-production-approval.py [circleci-config]")

DOCKERFILE_PATH = REPOSITORY_ROOT / "ECSDockerfile"
NGINX_SOURCE_ROOT = REPOSITORY_ROOT / "src"
BUILD_SCRIPT_PATH = REPOSITORY_ROOT / "buildimage.sh"
BUILD_AWS_SCRIPT_PATH = REPOSITORY_ROOT / "scripts" / "configure-production-build-aws.sh"
DEPLOY_AWS_SCRIPT_PATH = REPOSITORY_ROOT / "scripts" / "configure-production-deploy-aws.sh"
SNAPSHOT_AWS_SCRIPT_PATH = (
    REPOSITORY_ROOT / "scripts" / "configure-production-deployvar-snapshot-aws.sh"
)
SNAPSHOT_POLICY_SCRIPT_PATH = (
    REPOSITORY_ROOT / "scripts" / "generate-production-snapshot-session-policy.sh"
)
SNAPSHOT_POLICY_TEST_PATH = (
    REPOSITORY_ROOT / "scripts" / "test-production-snapshot-session-policy.sh"
)
NONPRODUCTION_AWS_SCRIPT_PATH = (
    REPOSITORY_ROOT / "scripts" / "configure-nonproduction-aws.sh"
)
NONPRODUCTION_AWS_CLEANUP_PATH = (
    REPOSITORY_ROOT / "scripts" / "cleanup-nonproduction-aws.sh"
)
NONPRODUCTION_AWS_TEST_PATH = (
    REPOSITORY_ROOT / "scripts" / "test-configure-nonproduction-aws.sh"
)
SSM_LOADER_PATH = REPOSITORY_ROOT / "scripts" / "load-ssm-environment.sh"
SSM_LOADER_TEST_PATH = REPOSITORY_ROOT / "scripts" / "test-load-ssm-environment.sh"
VERSIONED_SSM_TEST_PATH = (
    REPOSITORY_ROOT / "scripts" / "test-versioned-ssm-environment.sh"
)
SNAPSHOT_AWS_TEST_PATH = (
    REPOSITORY_ROOT / "scripts" / "test-configure-production-snapshot-aws.sh"
)
RETIRED_PROVIDER_TEST_PATH = REPOSITORY_ROOT / "scripts" / "test-retired-provider-routes.sh"
PROVIDER_IMAGE_TEST_PATH = REPOSITORY_ROOT / "scripts" / "verify-provider-off-image.sh"
EFS_VALIDATOR_PATH = REPOSITORY_ROOT / "scripts" / "validate-efs-mapping.sh"
EFS_VALIDATOR_TEST_PATH = REPOSITORY_ROOT / "scripts" / "test-efs-mapping.sh"
TASK_DEFINITION_TEST_PATH = (
    REPOSITORY_ROOT / "scripts" / "test-task-definition-contract.py"
)
RUNTIME_ENTRYPOINT_PATH = REPOSITORY_ROOT / "rund"
RUNTIME_TEST_PATH = REPOSITORY_ROOT / "scripts" / "test-runtime.sh"
CIRCLECI_CONFIG_TEST_PATH = REPOSITORY_ROOT / "scripts" / "test-circleci-config.sh"
AUTHORITY_GATE_TEST_PATH = (
    REPOSITORY_ROOT / "scripts" / "test-production-authority-gates.sh"
)
TOOLING_REQUIREMENTS_PATH = (
    REPOSITORY_ROOT / "scripts" / "production-tooling-requirements.txt"
)


def fail(message: str) -> None:
    raise SystemExit(message)


def require_markers(text: str, markers: tuple[str, ...], label: str) -> None:
    for marker in markers:
        if marker not in text:
            fail(f"{label} is missing: {marker}")


def step_commands(steps: list[Any], step_type: str | None = None) -> str:
    commands: list[str] = []
    for step in steps:
        if not isinstance(step, dict):
            continue
        for current_type, value in step.items():
            if step_type is not None and current_type != step_type:
                continue
            if isinstance(value, dict) and isinstance(value.get("command"), str):
                commands.append(value["command"])
    return "\n".join(commands)


config_text = CONFIG_PATH.read_text(encoding="utf-8")
try:
    config = yaml.safe_load(config_text)
except yaml.YAMLError as error:
    fail(f"CircleCI config is invalid YAML: {error}")
if not isinstance(config, dict):
    fail("CircleCI config must resolve to a mapping.")
for forbidden_legacy_loader in (
    "psvar-processor.sh",
    "source buildvar_env",
    "source deployvar_env",
    "source awsenvconf",
    "awsconfiguration.sh",
):
    if forbidden_legacy_loader in config_text:
        fail(
            "CircleCI must not evaluate generated SSM shell files: "
            f"{forbidden_legacy_loader}"
        )
require_markers(
    config_text,
    (
        'load_ssm_environment "${SSM_CONFIG_ROOT}/buildvar"',
        'load_ssm_environment "${SSM_CONFIG_ROOT}/deployvar"',
        '--path "${SSM_CONFIG_ROOT}/appvar"',
        'type == "array" and length == 0',
    ),
    "Safe non-production parameter loading",
)

expected_workflow_jobs = [
    {
        "build-dev": {
            "context": "docker-nginx-supply-dev-deploy",
            "filters": {
                "branches": {"only": ["dev", "dev-nginx118", "CORE-799-fix-v1"]}
            },
        }
    },
    {
        "prepare-prod-tooling": {
            "filters": {"branches": {"only": "master"}},
        }
    },
    {
        "approve-prod": {
            "type": "approval",
            "requires": ["prepare-prod-tooling"],
            "filters": {"branches": {"only": "master"}},
        }
    },
    {
        "build-prod": {
            "context": "docker-nginx-supply-prod-build",
            "requires": ["approve-prod"],
            "filters": {"branches": {"only": "master"}},
        }
    },
    {
        "verify-prod": {
            "requires": ["build-prod"],
            "filters": {"branches": {"only": "master"}},
        }
    },
    {
        "snapshot-prod-deployvars": {
            "context": "docker-nginx-supply-prod-deployvar-snapshot",
            "requires": ["verify-prod"],
            "filters": {"branches": {"only": "master"}},
        }
    },
    {
        "approve-prod-deploy": {
            "type": "approval",
            "requires": ["snapshot-prod-deployvars"],
            "filters": {"branches": {"only": "master"}},
        }
    },
    {
        "deploy-prod": {
            "context": "docker-nginx-supply-prod-deploy",
            "serial-group": "<< pipeline.project.slug >>/production-ecs",
            "requires": ["approve-prod-deploy"],
            "filters": {"branches": {"only": "master"}},
        }
    },
    {
        "build-qa": {
            "context": "docker-nginx-supply-qa-deploy",
            "filters": {"branches": {"only": "qa"}},
        }
    },
]
try:
    workflow_jobs = config["workflows"]["build"]["jobs"]
except (KeyError, TypeError) as error:
    raise SystemExit("CircleCI build workflow is missing.") from error
if workflow_jobs != expected_workflow_jobs:
    fail(
        "Resolved workflow jobs must exactly preserve dev/QA filters and the ordered "
        "no-authority tooling -> build approval -> least-privilege build -> "
        "no-authority verification -> deploy approval -> deploy chain."
    )

try:
    jobs = config["jobs"]
    development_job = jobs["build-dev"]
    qa_job = jobs["build-qa"]
    tooling_job = jobs["prepare-prod-tooling"]
    build_job = jobs["build-prod"]
    verify_job = jobs["verify-prod"]
    snapshot_job = jobs["snapshot-prod-deployvars"]
    deploy_job = jobs["deploy-prod"]
    tooling_steps = tooling_job["steps"]
    build_steps = build_job["steps"]
    verify_steps = verify_job["steps"]
    snapshot_steps = snapshot_job["steps"]
    deploy_steps = deploy_job["steps"]
except (KeyError, TypeError) as error:
    raise SystemExit("Resolved production job definitions are incomplete.") from error
if not all(
    isinstance(steps, list)
    for steps in (tooling_steps, build_steps, verify_steps, snapshot_steps, deploy_steps)
):
    fail("Resolved production steps must be lists.")

expected_environment = {
    "DEPLOY_ENV": "PROD",
    "LOGICAL_ENV": "prod",
    "APPNAME": "docker-nginx-supply",
    "AWS_REGION": "us-east-1",
    "EXPECTED_AWS_ACCOUNT_ID": "409275337247",
    "PRODUCTION_AUTHORITY_BOUNDARY_STATUS": "BLOCKED_SAME_PROJECT_OIDC",
    "EXPECTED_AWS_ECS_VOLUMES_EFS_SHA256": "INVENTORY_REQUIRED",
}
if build_job.get("environment") != expected_environment:
    fail("Production build environment must be the exact non-secret release contract.")
if deploy_job.get("environment") != expected_environment:
    fail("Production deploy environment must be the exact non-secret release contract.")
expected_verify_environment = {
    "DEPLOY_ENV": "PROD",
    "LOGICAL_ENV": "prod",
    "APPNAME": "docker-nginx-supply",
}
if verify_job.get("environment") != expected_verify_environment:
    fail("Production verification must not receive an AWS environment contract.")
if tooling_job.get("environment") is not None:
    fail("Production tooling preparation must not receive job environment authority.")

expected_snapshot_environment = {
    **expected_verify_environment,
    "AWS_REGION": "us-east-1",
    "EXPECTED_AWS_ACCOUNT_ID": "409275337247",
    "PRODUCTION_AUTHORITY_BOUNDARY_STATUS": "BLOCKED_SAME_PROJECT_OIDC",
    "EXPECTED_AWS_ECS_VOLUMES_EFS_SHA256": "INVENTORY_REQUIRED",
}
if snapshot_job.get("environment") != expected_snapshot_environment:
    fail("Production snapshot environment must be the exact non-secret read contract.")
expected_development_environment = {
    "DEPLOY_ENV": "DEV",
    "LOGICAL_ENV": "dev",
    "APPNAME": "docker-nginx-supply",
    "SSM_CONFIG_ROOT": "/config/docker-nginx-supply/dev",
    "EXPECTED_NONPRODUCTION_AWS_ACCOUNT_ID": "811668436784",
    "EXPECTED_NONPRODUCTION_AWS_ROLE_NAME": (
        "circleci-docker-nginx-supply-dev-deploy"
    ),
    "EXPECTED_AWS_ECS_VOLUMES_EFS_SHA256": "INVENTORY_REQUIRED",
}
expected_qa_environment = {
    "DEPLOY_ENV": "QA",
    "LOGICAL_ENV": "qa",
    "APPNAME": "docker-nginx-supply",
    "SSM_CONFIG_ROOT": "/config/docker-nginx-supply/qa",
    "EXPECTED_NONPRODUCTION_AWS_ACCOUNT_ID": "INVENTORY_REQUIRED",
    "EXPECTED_NONPRODUCTION_AWS_ROLE_NAME": (
        "circleci-docker-nginx-supply-qa-deploy"
    ),
    "EXPECTED_AWS_ECS_VOLUMES_EFS_SHA256": "INVENTORY_REQUIRED",
}
if development_job.get("environment") != expected_development_environment:
    fail("Development must use its exact repo-owned account, role, and path contract.")
if qa_job.get("environment") != expected_qa_environment:
    fail("QA must remain fail-closed until its account inventory is committed.")
if (
    expected_development_environment["SSM_CONFIG_ROOT"]
    == expected_qa_environment["SSM_CONFIG_ROOT"]
):
    fail("Development and QA must never share an SSM parameter namespace.")
if "org-global" in config_text:
    fail("Supply jobs must not inherit the broad org-global context.")
development_commands = step_commands(development_job.get("steps", []))
qa_commands = step_commands(qa_job.get("steps", []))
if development_commands != qa_commands:
    fail("Development and QA must resolve the same hardened build/deploy steps.")
require_markers(
    development_commands,
    (
        './scripts/configure-nonproduction-aws.sh "${DEPLOY_ENV}"',
        'load_ssm_environment "${SSM_CONFIG_ROOT}/buildvar"',
        'load_ssm_environment "${SSM_CONFIG_ROOT}/deployvar"',
        "for forbidden_runtime_override_variable in",
        "AWS_ECS_TASK_ROLE_ARN",
        "AWS_ECS_TASK_EXECUTION_ROLE_ARN",
        "export AWS_ECS_TASK_ROLE_ARN=''",
        "readonly AWS_ECS_TASK_ROLE_ARN AWS_ECS_TASK_EXECUTION_ROLE_ARN",
        "AWS_ECS_VOLUMES_EFS",
        "source ./scripts/validate-efs-mapping.sh",
        "validate_efs_mapping",
        "EXPECTED_AWS_ECS_VOLUMES_EFS_SHA256",
        'type == "array" and length == 0',
        "./scripts/verify-no-retired-provider-routes.py -",
        "cleanup-nonproduction-aws.sh",
        "EXPECTED_NONPRODUCTION_AWS_ACCOUNT_ID",
        "NONPRODUCTION_AWS_CREDENTIAL_DIRECTORY",
    ),
    "Non-production resolved jobs",
)
nonproduction_forbidden_start = development_commands.index(
    "for forbidden_runtime_override_variable in"
)
nonproduction_forbidden_end = development_commands.index(
    'load_ssm_environment "${SSM_CONFIG_ROOT}/deployvar"',
    nonproduction_forbidden_start,
)
nonproduction_forbidden_command = development_commands[
    nonproduction_forbidden_start:nonproduction_forbidden_end
]
for forbidden_runtime_override in (
    "AWS_ECS_TASK_ROLE_ARN",
    "AWS_ECS_TASK_EXECUTION_ROLE_ARN",
    "AWS_ECS_VOLUMES",
    "AWS_ECS_CONTAINER_HEALTH_CMD",
    "AWS_ECS_CONTAINER_CMD",
):
    if not re.search(
        rf"\b{re.escape(forbidden_runtime_override)}\b",
        nonproduction_forbidden_command,
    ):
        fail(
            "Non-production must reject inherited task override: "
            f"{forbidden_runtime_override}"
        )
if re.search(r"\bAWS_ECS_VOLUMES_EFS\b", nonproduction_forbidden_command):
    fail("Non-production must load and hash-validate EFS instead of rejecting it.")
if '-j "${SSM_CONFIG_ROOT}/appvar"' in development_commands:
    fail("Non-production deploys must not inject runtime appvar secrets.")
if '/config/${APPNAME}/' in development_commands:
    fail("Non-production jobs must not use the shared legacy SSM namespace.")

expected_production_docker = [
    {
        "image": "cimg/python:3.13.2-browsers@sha256:882c0efbf6c617fd18eed8cea5db0949a5bebe3af8465a6c52700140cc24067a"
    }
]
for job_name, job in (
    ("prepare-prod-tooling", tooling_job),
    ("build-prod", build_job),
    ("verify-prod", verify_job),
    ("snapshot-prod-deployvars", snapshot_job),
    ("deploy-prod", deploy_job),
):
    if job.get("docker") != expected_production_docker:
        fail(f"{job_name} must use the exact reviewed executor image digest.")
    if job.get("resource_class") != "medium.gen2":
        fail(f"{job_name} must use the reviewed Gen2 executor class.")

for job_name, steps in (
    ("build-prod", build_steps),
    ("verify-prod", verify_steps),
    ("deploy-prod", deploy_steps),
):
    remote_docker_versions = [
        step["setup_remote_docker"].get("version")
        for step in steps
        if isinstance(step, dict) and isinstance(step.get("setup_remote_docker"), dict)
    ]
    if remote_docker_versions != ["docker28"]:
        fail(f"{job_name} must pin exactly one Docker 28 remote engine.")

tooling_commands = step_commands(tooling_steps)
for forbidden in (
    "aws sts ",
    "aws ssm ",
    "aws ecr ",
    "aws ecs ",
    "buildimage.sh",
    "master_deploy.sh -",
    "CIRCLE_OIDC_TOKEN",
):
    if forbidden in tooling_commands:
        fail(f"Production tooling preparation contains authority or release work: {forbidden}")
require_markers(
    tooling_commands,
    (
        "--require-hashes",
        "--no-deps",
        "scripts/production-tooling-requirements.txt",
        "f2fa1d1b8d57c635176ef5a3a6f0e0425e88fdbe",
        "55be8659807ee2d80f00078b0c4aa483adae222ddf2adc9db23f25ea64c02886",
        "7a946096255d2532d3bd020a49b67ee09f8d742dfcd5d15949aee8b8af1ea234",
        "scripts/master-deploy-immutable-retry.patch",
        "circleci-cli_${circleci_cli_version}_linux_amd64.tar.gz",
        "c7c10708b271b88573f7c73ba314bc4d3d495a8c0b21f0648d9250b2dee347bd",
        "b1db12daab590229e591fd9899d08783685c9e0ac1bf451b3f0671e5b4032294",
        '"${tooling_directory}/venv/bin/python"',
        "./scripts/test-circleci-config.sh",
        "tooling-manifest.txt",
    ),
    "Production tooling preparation",
)
if any(
    isinstance(step, dict) and "setup_remote_docker" in step for step in tooling_steps
):
    fail("Production tooling preparation must not start a remote Docker engine.")
if not any(
    isinstance(step, dict) and "persist_to_workspace" in step for step in tooling_steps
):
    fail("Production tooling preparation must persist the reviewed toolchain.")
if not any(isinstance(step, dict) and "store_artifacts" in step for step in tooling_steps):
    fail("Production tooling preparation must publish its non-secret manifest.")

tooling_requirements_text = TOOLING_REQUIREMENTS_PATH.read_text(encoding="utf-8")
require_markers(
    tooling_requirements_text,
    (
        "awscli==1.46.0",
        "pyyaml==6.0.3",
        "urllib3==2.7.0",
        "--hash=sha256:",
    ),
    "Hash-locked production tooling",
)

if any(isinstance(step, dict) and "deploy" in step for step in build_steps):
    fail("Production build must not contain a resolved deploy step.")
build_commands = step_commands(build_steps)
for forbidden in (
    "master_deploy.sh",
    "awsconfiguration.sh",
    "/deployvar",
    "aws ecr ",
    "aws ecs ",
    "pip install",
    "git clone",
    "sudo ",
):
    if forbidden in build_commands:
        fail(f"Production build contains deployment authority: {forbidden}")
require_markers(
    build_commands,
    (
        "./scripts/configure-production-build-aws.sh \\\n  ENV_PLATFORM_UI_RESOLVER",
        "AWS_EC2_METADATA_DISABLED=true",
        '${tooling_directory}/venv/bin',
        'load_ssm_environment "/config/${APPNAME}/buildvar"',
        './buildimage.sh "${DEPLOY_ENV}"',
        "docker save nginx-supply:latest",
        "docker-server-version.txt",
        "archive_config_sha256",
        "release-manifest.txt",
    ),
    "Production build",
)
if "ENV_NETLIFY" in build_commands:
    fail("Provider-off production build must not request the retired origin parameter.")
build_credential_positions = [
    build_commands.index("AWS_EC2_METADATA_DISABLED=true"),
    build_commands.index("./scripts/configure-production-build-aws.sh"),
    build_commands.index("unset CIRCLE_OIDC_TOKEN CIRCLE_OIDC_TOKEN_V2"),
    build_commands.index('load_ssm_environment "/config/${APPNAME}/buildvar"'),
    build_commands.rindex("cleanup_build_credentials"),
    build_commands.index('./buildimage.sh "${DEPLOY_ENV}"'),
    build_commands.index("unset AWS_EC2_METADATA_DISABLED"),
]
if build_credential_positions != sorted(build_credential_positions):
    fail("Production build must drop its OIDC token and AWS credentials before image code runs.")
if not any(isinstance(step, dict) and "persist_to_workspace" in step for step in build_steps):
    fail("Production build must persist its exact image to the workflow workspace.")
if not any(isinstance(step, dict) and "store_artifacts" in step for step in build_steps):
    fail("Production build must publish its non-secret approval manifest.")

verify_commands = step_commands(verify_steps)
for forbidden in (
    "configure-production-build-aws.sh",
    "configure-production-deploy-aws.sh",
    "load_ssm_environment",
    "aws sts ",
    "aws ssm ",
    "aws ecr ",
    "aws ecs ",
    "CIRCLE_OIDC_TOKEN",
    "pip install",
    "git clone",
):
    if forbidden in verify_commands:
        fail(f"Production verification contains AWS authority or mutable tooling: {forbidden}")
require_markers(
    verify_commands,
    (
        "sha256sum --check --strict nginx-supply.tar.gz.sha256",
        "archive_config_sha256",
        "docker-server-version.txt",
        'gzip --decompress --stdout "${release_directory}/nginx-supply.tar.gz" | docker load',
        "./scripts/test-production-approval.py",
        "./scripts/test-load-ssm-environment.sh",
        "./scripts/test-versioned-ssm-environment.sh",
        "./scripts/test-configure-nonproduction-aws.sh",
        "./scripts/test-production-authority-gates.sh",
        "./scripts/test-configure-production-snapshot-aws.sh",
        "./scripts/test-production-snapshot-session-policy.sh",
        "./scripts/test-efs-mapping.sh",
        "./scripts/test-task-definition-contract.py",
        "./scripts/test-community-app-cdn-route.sh",
        "./scripts/test-runtime.sh nginx-supply:latest",
        './scripts/verify-provider-off-image.sh nginx-supply:latest "${CIRCLE_SHA1}"',
        "./scripts/test-retired-provider-routes.sh",
        "verification-manifest.txt",
    ),
    "No-authority production verification",
)
if (
    RETIRED_PROVIDER_TEST_PATH.exists()
    and "./scripts/test-retired-provider-routes.sh" not in verify_commands
):
    fail("Provider-off production verification must run the retired-provider contract.")
if not any(
    isinstance(step, dict) and "persist_to_workspace" in step for step in verify_steps
):
    fail("Production verification must persist its evidence for the deploy job.")
if not any(isinstance(step, dict) and "store_artifacts" in step for step in verify_steps):
    fail("Production verification must publish its non-secret evidence manifest.")

snapshot_commands = step_commands(snapshot_steps)
for forbidden in (
    "docker ",
    "aws ecr ",
    "aws ecs ",
    "aws iam ",
    "master_deploy.sh",
    "buildimage.sh",
    "PutParameter",
    "DeleteParameter",
):
    if forbidden in snapshot_commands:
        fail(f"Production deploy-variable snapshot contains mutation authority: {forbidden}")
require_markers(
    snapshot_commands,
    (
        "configure-production-deployvar-snapshot-aws.sh",
        "snapshot_ssm_environment",
        '"/config/${APPNAME}/deployvar"',
        "deployvar-versions.tsv",
        "deployvar-versions.tsv.sha256",
        "deployvar-snapshot-manifest.txt",
        "deployvar_present_count",
        "deployvar_absent_optional_count",
        "cleanup_snapshot_credentials",
        "unset CIRCLE_OIDC_TOKEN CIRCLE_OIDC_TOKEN_V2",
    ),
    "Production deploy-variable snapshot",
)
if any(
    isinstance(step, dict) and "setup_remote_docker" in step for step in snapshot_steps
):
    fail("The read-only deploy-variable snapshot must not start Docker.")
if not any(
    isinstance(step, dict) and "persist_to_workspace" in step for step in snapshot_steps
):
    fail("The deploy-variable snapshot must persist exact-version evidence.")
if sum(
    1 for step in snapshot_steps if isinstance(step, dict) and "store_artifacts" in step
) != 2:
    fail("The deploy-variable snapshot must publish metadata and its approval manifest.")
snapshot_authority_positions = [
    snapshot_commands.index("configure-production-deployvar-snapshot-aws.sh"),
    snapshot_commands.index("unset CIRCLE_OIDC_TOKEN CIRCLE_OIDC_TOKEN_V2"),
    snapshot_commands.index("snapshot_ssm_environment"),
    snapshot_commands.rindex("cleanup_snapshot_credentials"),
]
if snapshot_authority_positions != sorted(snapshot_authority_positions):
    fail("The snapshot job must drop both OIDC tokens immediately after role assumption.")

deploy_commands = step_commands(deploy_steps)
for forbidden in (
    "buildimage.sh",
    "docker build",
    "/buildvar",
    "source deployvar_env",
    'psvar-processor.sh -t appenv -p "/config/${APPNAME}/deployvar"',
    "-i nginx-supply",
    "aws ecr describe-images",
    '${HOME}/.docker',
    "awsconfiguration.sh",
    "CI_AUTH0_",
    "curl -k",
    "pip install",
    "git clone",
    "sudo ",
    "./scripts/test-production-approval.py",
    "./scripts/test-community-app-cdn-route.sh",
    "./scripts/test-load-ssm-environment.sh",
    "./scripts/test-versioned-ssm-environment.sh",
    "./scripts/test-netlify-origin.sh",
    "./scripts/test-retired-provider-routes.sh",
):
    if forbidden in deploy_commands:
        fail(f"Production deploy can rebuild or unsafely replace the artifact: {forbidden}")
if any(isinstance(step, dict) and "deploy" in step for step in deploy_steps):
    fail("Production deploy must use the current run step, not deprecated deploy syntax.")
deploy_step_indexes = [
    index
    for index, step in enumerate(deploy_steps)
    if isinstance(step, dict)
    and isinstance(step.get("run"), dict)
    and step["run"].get("name") == "Deploy the approved production image"
]
if len(deploy_step_indexes) != 1:
    fail("Production deploy must contain exactly one resolved deploy step.")
verify_step_index = next(
    (
        index
        for index, step in enumerate(deploy_steps)
        if isinstance(step, dict)
        and isinstance(step.get("run"), dict)
        and step["run"].get("name")
        == "Reverify the approved production inputs before assuming the deploy role"
    ),
    -1,
)
if verify_step_index < 0 or verify_step_index >= deploy_step_indexes[0]:
    fail("The exact image verifier must run before the sole production deploy step.")
reverify_command = deploy_steps[verify_step_index]["run"]["command"]
for forbidden in (
    "CIRCLE_OIDC_TOKEN",
    "configure-production-deploy-aws.sh",
    "load_ssm_environment",
    "aws sts ",
    "aws ssm ",
    "aws ecr ",
    "aws ecs ",
):
    if forbidden in reverify_command:
        fail(f"Pre-assumption deploy revalidation contains AWS authority: {forbidden}")

required_deploy_markers = (
    "sha256sum --check --strict nginx-supply.tar.gz.sha256",
    'gzip --decompress --stdout "${release_directory}/nginx-supply.tar.gz" | docker load',
    "archive_config_sha256",
    "docker-server-version.txt",
    "verification-manifest.txt",
    "release-manifest.txt",
    "./scripts/test-runtime.sh nginx-supply:latest",
    './scripts/verify-provider-off-image.sh nginx-supply:latest "${CIRCLE_SHA1}"',
    "deployvar-versions.tsv.sha256",
    "deployvar-snapshot-manifest.txt",
    'deployvar_absent_count="$((12 - deployvar_present_count))"',
    "7a946096255d2532d3bd020a49b67ee09f8d742dfcd5d15949aee8b8af1ea234",
    "2739b4981a18cbf7394689262f55f7bbb85c773bb8d2261108ca8e23b1fccc4e",
    "b1db12daab590229e591fd9899d08783685c9e0ac1bf451b3f0671e5b4032294",
    "./scripts/test-circleci-config.sh",
    '"${tooling_directory}/venv/bin/python"',
    "for inherited_credential_name in",
    "AWS_CONTAINER_CREDENTIALS_FULL_URI",
    "AWS_CA_BUNDLE",
    "compgen -A variable AWS_ENDPOINT_URL_",
    "mktemp -d /tmp/nginx-supply-deploy-credentials.XXXXXX",
    'export DOCKER_CONFIG="${credential_directory}/docker"',
    "AWS_EC2_METADATA_DISABLED=true",
    "./scripts/configure-production-deploy-aws.sh",
    "unset CIRCLE_OIDC_TOKEN CIRCLE_OIDC_TOKEN_V2",
    "circleci-docker-nginx-supply-prod-deploy",
    "for forbidden_task_override_variable in",
    "Production deploy received a forbidden task override",
    "load_ssm_environment_from_manifest",
    '"/config/${expected_appname}/deployvar"',
    '"${release_directory}/deployvar-versions.tsv"',
    'test "${AWS_ECS_READONLY_ROOTFILESYSTEM}" = false',
    "export AWS_ECS_VOLUMES=''",
    "AWS_ECS_CONTAINER_HEALTH_CMD=''",
    "AWS_ECS_CONTAINER_CMD=''",
    "source ./scripts/validate-efs-mapping.sh",
    "validate_efs_mapping",
    '"${AWS_ECS_VOLUMES_EFS}"',
    '"${EXPECTED_AWS_ECS_VOLUMES_EFS_SHA256}"',
    "./scripts/verify-no-retired-provider-routes.py -",
    'readonly appvar_path="/config/${expected_appname}/appvar"',
    "aws ssm get-parameters-by-path",
    "--no-recursive",
    "(length == 0)",
    "expected-runtime-parameter-references.tsv",
    "imageTagMutability",
    'test "${repository_mutability}" = IMMUTABLE',
    'docker tag "${approved_image_id}" "${registry_image}"',
    '-t "${approved_source_sha}"',
    "imageTag=${approved_source_sha}",
    "batch-get-image",
    "ECS_SKIP_ECR_PUSH",
    "ImageNotFound",
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    ".images[0].imageId.imageDigest",
    'test "${remote_config_digest}" = "${approved_config_digest}"',
    'test "${post_push_repository_mutability}" = IMMUTABLE',
    "aws ecs describe-clusters",
    "aws ecs describe-services",
    "aws logs describe-log-groups",
    "aws ecs wait services-stable",
    ".desiredCount > 0",
    '.deployments[0].rolloutState == "COMPLETED"',
    "previous-service-task-definitions.txt",
    "ecsTaskExecutionRole",
    '((.taskDefinition.taskRoleArn // "") == "")',
    ".readonlyRootFilesystem == false",
    "((.taskDefinition.volumes // []) | length) == 1",
    ' --arg efs_volume_name "${VALIDATED_EFS_VOLUME_NAME}"',
    ' --arg efs_root_directory "${VALIDATED_EFS_ROOT_DIRECTORY}"',
    ' --arg efs_container_path "${VALIDATED_EFS_CONTAINER_PATH}"',
    ' --arg efs_filesystem_id "${VALIDATED_EFS_FILESYSTEM_ID}"',
    '--argjson expected_port_mappings "${expected_port_mappings}"',
    '--arg expected_container_memory_reservation',
    '--arg expected_container_cpu',
    '--arg expected_fargate_cpu',
    '--arg expected_fargate_memory',
    ".taskDefinition.cpu == $expected_fargate_cpu",
    ".taskDefinition.memory == $expected_fargate_memory",
    ".efsVolumeConfiguration.fileSystemId == $efs_filesystem_id",
    ".efsVolumeConfiguration.rootDirectory == $efs_root_directory",
    '((.efsVolumeConfiguration.transitEncryption // "DISABLED") == "DISABLED")',
    "((.efsVolumeConfiguration.authorizationConfig // null) == null)",
    "((.taskDefinition.containerDefinitions // []) | length) == 1",
    ".essential == true",
    ".memoryReservation == ($expected_container_memory_reservation | tonumber)",
    ".cpu == ($expected_container_cpu | tonumber)",
    "sort_by(.containerPort, .hostPort, .protocol)) == $expected_port_mappings",
    "((.entryPoint // []) | length) == 0",
    "((.command // []) | length) == 0",
    "(.healthCheck // null) == null",
    "((.mountPoints // []) | length) == 1",
    ".sourceVolume == $efs_volume_name",
    ".containerPath == $efs_container_path",
    "((.volumesFrom // []) | length) == 0",
    "((.environment // []) | length) == 0",
    "((.secrets // []) | length) == 0",
    "cmp --silent",
    "deployment-manifest.txt",
    "efs_mapping_sha256",
    "deployvar_versions_sha256",
)
require_markers(deploy_commands, required_deploy_markers, "Production deploy")
if '-j "/config/${expected_appname}/appvar"' in deploy_commands:
    fail("Production deploy must not inject runtime appvar secrets.")
deploy_loader_start = deploy_commands.index(
    "load_ssm_environment_from_manifest"
)
deploy_loader_end = deploy_commands.index(
    'export AWS_ACCOUNT_ID="${caller_account_id}"', deploy_loader_start
)
deploy_loader_command = deploy_commands[deploy_loader_start:deploy_loader_end]
for forbidden_role_variable in (
    "AWS_ECS_TASK_ROLE_ARN",
    "AWS_ECS_TASK_EXECUTION_ROLE_ARN",
    "AWS_ECS_VOLUMES",
    "AWS_ECS_CONTAINER_HEALTH_CMD",
    "AWS_ECS_CONTAINER_CMD",
):
    if re.search(rf"\b{re.escape(forbidden_role_variable)}\b", deploy_loader_command):
        fail(
            "Production deploy must reject task overrides instead of loading "
            f"{forbidden_role_variable} from SSM."
        )
if deploy_commands.count("aws ecr batch-get-image") != 2:
    fail("Production deploy must inspect the immutable tag before and after the helper.")
ordered_deploy_markers = (
    "for inherited_credential_name in",
    "./scripts/configure-production-deploy-aws.sh",
    "unset CIRCLE_OIDC_TOKEN CIRCLE_OIDC_TOKEN_V2",
    "load_ssm_environment_from_manifest",
    "validate_efs_mapping",
    "expected_port_mappings",
    "aws ecs describe-clusters",
    "aws ecs describe-services",
    "aws logs describe-log-groups",
    "imageTagMutability",
    'docker tag "${approved_image_id}" "${registry_image}"',
    '"${master_deploy_path}" \\\n  -d ECS',
    "remote_image_response",
    'test "${remote_config_digest}" = "${approved_config_digest}"',
    'test "${post_push_repository_mutability}" = IMMUTABLE',
    "aws ecs wait services-stable",
    "deployed_services_response",
    'test "${task_definition_arn}" != "${previous_task_definitions[$service]}"',
    "cmp --silent",
)
positions = [deploy_commands.index(marker) for marker in ordered_deploy_markers]
if positions != sorted(positions):
    fail("Production deploy identity checks are not in the required order.")
if not any(isinstance(step, dict) and "store_artifacts" in step for step in deploy_steps):
    fail("Production deploy must publish its registry/service identity manifest.")

build_aws_text = BUILD_AWS_SCRIPT_PATH.read_text(encoding="utf-8")
require_markers(
    build_aws_text,
    (
        "CIRCLE_OIDC_TOKEN_V2",
        "VERIFIED_EXTERNAL_AUTHORITY_GATE",
        "arn:aws:iam::409275337247:role/circleci-docker-nginx-supply-prod-build",
        "AWS_PRODUCTION_BUILD_ROLE_ARN",
        "AWS_PRODUCTION_BUILD_KMS_KEY_ARN",
        "assume-role-with-web-identity",
        '"ssm:GetParameters"',
        '"kms:ViaService"',
        '"kms:EncryptionContext:PARAMETER_ARN"',
        "--duration-seconds 900",
        "--policy",
        "Production build context injected a forbidden AWS provider",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
        "AWS_WEB_IDENTITY_TOKEN_FILE",
        "AWS_CA_BUNDLE",
        "compgen -A variable AWS_ENDPOINT_URL_",
        "get-caller-identity",
        "assumed-role/circleci-docker-nginx-supply-prod-build/${session_name}",
    ),
    "Production build-role setup",
)
if "ENV_NETLIFY" in build_aws_text:
    fail("Provider-off build role must not allow the retired origin parameter.")
deploy_aws_text = DEPLOY_AWS_SCRIPT_PATH.read_text(encoding="utf-8")
require_markers(
    deploy_aws_text,
    (
        "CIRCLE_OIDC_TOKEN_V2",
        "arn:aws:iam::409275337247:role/${expected_role_name}",
        "circleci-docker-nginx-supply-prod-deploy",
        "VERIFIED_EXTERNAL_AUTHORITY_GATE",
        "assume-role-with-web-identity",
        "--duration-seconds 3600",
        "AWS_CONFIG_FILE",
        "AWS_SHARED_CREDENTIALS_FILE",
        "AWS_CA_BUNDLE",
        "compgen -A variable AWS_ENDPOINT_URL_",
        "get-caller-identity",
        "assumed-role/${expected_role_name}/${session_name}",
    ),
    "Production deploy-role setup",
)
snapshot_aws_text = SNAPSHOT_AWS_SCRIPT_PATH.read_text(encoding="utf-8")
snapshot_policy_text = SNAPSHOT_POLICY_SCRIPT_PATH.read_text(encoding="utf-8")
require_markers(
    snapshot_aws_text,
    (
        "circleci-docker-nginx-supply-prod-deployvar-snapshot",
        "VERIFIED_EXTERNAL_AUTHORITY_GATE",
        "AWS_PRODUCTION_DEPLOYVAR_SNAPSHOT_ROLE_ARN",
        "generate-production-snapshot-session-policy.sh",
        "${#session_policy} > 2048",
        "--duration-seconds 900",
        "assume-role-with-web-identity",
        "Production snapshot context injected a forbidden AWS provider",
    ),
    "Production deploy-variable snapshot role setup",
)
require_markers(
    snapshot_policy_text,
    (
        'Action: "ssm:GetParameters"',
        "/config/docker-nginx-supply/deployvar/*",
        "exact 12 parameter ARNs",
        "effective session permissions are their intersection",
        "Snapshot reads never decrypt values",
    ),
    "Production deploy-variable snapshot session policy",
)
for forbidden in (
    'Action: "ecr:',
    'Action: "ecs:',
    'Action: "iam:',
    'Action: "kms:',
    "ssm:Put",
    "ssm:Delete",
    "GetParametersByPath",
):
    if forbidden in snapshot_aws_text or forbidden in snapshot_policy_text:
        fail(f"Snapshot role setup contains excessive authority: {forbidden}")
for parameter_name in (
    "AWS_REPOSITORY",
    "AWS_ECS_CLUSTER",
    "AWS_ECS_SERVICE",
    "AWS_ECS_TASK_FAMILY",
    "AWS_ECS_CONTAINER_NAME",
    "AWS_ECS_PORTS",
    "AWS_ECS_READONLY_ROOTFILESYSTEM",
    "AWS_ECS_VOLUMES_EFS",
    "AWS_ECS_CONTAINER_MEMORY_RESERVATION",
    "AWS_ECS_CONTAINER_CPU",
    "AWS_ECS_FARGATE_CPU",
    "AWS_ECS_FARGATE_MEMORY",
):
    if len(re.findall(rf"\b{re.escape(parameter_name)}\b", snapshot_commands)) != 1:
        fail(f"Snapshot job must request deploy variable exactly once: {parameter_name}")
for forbidden_override_name in (
    "AWS_ECS_VOLUMES",
    "AWS_ECS_CONTAINER_HEALTH_CMD",
    "AWS_ECS_CONTAINER_CMD",
):
    if re.search(rf"\b{re.escape(forbidden_override_name)}\b", snapshot_commands):
        fail(f"Snapshot job must not approve runtime override: {forbidden_override_name}")
require_markers(
    snapshot_commands,
    (
        'wc -l | tr -d \' \')" = 12',
        'deployvar_absent_count="$((12 - deployvar_present_count))"',
    ),
    "Production deploy-variable snapshot cardinality",
)
for snapshot_policy_path in (SNAPSHOT_POLICY_SCRIPT_PATH, SNAPSHOT_POLICY_TEST_PATH):
    if not snapshot_policy_path.is_file() or not (
        snapshot_policy_path.stat().st_mode & 0o111
    ):
        fail(
            "Snapshot session-policy contract is missing or not executable: "
            f"{snapshot_policy_path}"
        )
if not SNAPSHOT_AWS_TEST_PATH.is_file() or not (
    SNAPSHOT_AWS_TEST_PATH.stat().st_mode & 0o111
):
    fail("Production snapshot AWS helper test is missing or not executable.")

for runtime_contract_path in (
    RUNTIME_TEST_PATH,
    PROVIDER_IMAGE_TEST_PATH,
    EFS_VALIDATOR_PATH,
    EFS_VALIDATOR_TEST_PATH,
    TASK_DEFINITION_TEST_PATH,
):
    if not runtime_contract_path.is_file() or not (
        runtime_contract_path.stat().st_mode & 0o111
    ):
        fail(f"Runtime image contract is missing or not executable: {runtime_contract_path}")
for compiler_or_gate_test_path in (CIRCLECI_CONFIG_TEST_PATH, AUTHORITY_GATE_TEST_PATH):
    if not compiler_or_gate_test_path.is_file() or not (
        compiler_or_gate_test_path.stat().st_mode & 0o111
    ):
        fail(f"Release-control regression test is missing or not executable: {compiler_or_gate_test_path}")

nonproduction_aws_text = NONPRODUCTION_AWS_SCRIPT_PATH.read_text(encoding="utf-8")
require_markers(
    nonproduction_aws_text,
    (
        "EXPECTED_NONPRODUCTION_AWS_ACCOUNT_ID",
        "EXPECTED_NONPRODUCTION_AWS_ROLE_NAME",
        "--disable",
        "--proto '=https'",
        "--tlsv1.2",
        "--data-binary",
        "aws sts get-caller-identity",
        "expected_caller_prefix",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
        "compgen -A variable AWS_ENDPOINT_URL_",
        "printf 'export AWS_ACCOUNT_ID=%q",
    ),
    "Non-production AWS setup",
)
for forbidden in ("curl -k", "--insecure", " eval ", "awsenvconf"):
    if forbidden in nonproduction_aws_text:
        fail(f"Non-production AWS setup contains unsafe generated-shell behavior: {forbidden}")
for nonproduction_contract_path in (
    NONPRODUCTION_AWS_CLEANUP_PATH,
    NONPRODUCTION_AWS_TEST_PATH,
):
    if not nonproduction_contract_path.is_file() or not (
        nonproduction_contract_path.stat().st_mode & 0o111
    ):
        fail(
            "Non-production credential lifecycle contract is missing or not executable: "
            f"{nonproduction_contract_path}"
        )
nonproduction_cleanup_text = NONPRODUCTION_AWS_CLEANUP_PATH.read_text(encoding="utf-8")
require_markers(
    nonproduction_cleanup_text,
    (
        "^/tmp/nginx-supply-nonprod-aws\\.[A-Za-z0-9]+$",
        '"${credential_directory}/config"',
        '"${credential_directory}/credentials"',
    ),
    "Non-production credential cleanup",
)
require_markers(
    config_text,
    ("'awscli==1.46.0'", "'PyYAML==6.0.3'"),
    "Pinned CircleCI dependencies",
)
ssm_loader_text = SSM_LOADER_PATH.read_text(encoding="utf-8")
if "get-parameters-by-path" in ssm_loader_text:
    fail("The SSM loader must request only the exact allowlisted parameter names.")
require_markers(
    ssm_loader_text,
    (
        "--required",
        "--optional",
        "get-parameters",
        "SecureString",
        "Allowlisted SSM variable is already set",
        "@base64",
        'printf -v "${loaded_names[$index]}"',
        "snapshot_ssm_environment",
        "load_ssm_environment_from_manifest",
        "nginx-supply-ssm-version-manifest-v1",
        ".Version",
        ".LastModifiedDate",
    ),
    "Safe SSM loader",
)
snapshot_function_text = ssm_loader_text.split("snapshot_ssm_environment()", 1)[1].split(
    "load_ssm_environment_from_manifest()", 1
)[0]
if "--with-decryption" in snapshot_function_text:
    fail("The metadata-only SSM snapshot must not receive KMS decrypt authority.")
executable_loader_text = "\n".join(
    line for line in ssm_loader_text.splitlines() if not line.lstrip().startswith("#")
)
if "eval" in executable_loader_text or "source" in executable_loader_text:
    fail("SSM parameter values must never be evaluated as shell source.")
if not SSM_LOADER_TEST_PATH.is_file():
    fail("Safe SSM loader regression test is missing.")
if not VERSIONED_SSM_TEST_PATH.is_file() or not VERSIONED_SSM_TEST_PATH.stat().st_mode & 0o111:
    fail("Versioned SSM snapshot/load regression test is missing or not executable.")
versioned_ssm_test_text = VERSIONED_SSM_TEST_PATH.read_text(encoding="utf-8")

def shell_array_values(text: str, name: str) -> tuple[str, ...]:
    match = re.search(
        rf"^{re.escape(name)}=\(\n(?P<body>.*?)^\)$",
        text,
        flags=re.MULTILINE | re.DOTALL,
    )
    if match is None:
        fail(f"Versioned SSM regression fixture is missing array: {name}")
    return tuple(
        line.strip()
        for line in match.group("body").splitlines()
        if line.strip()
    )


if shell_array_values(versioned_ssm_test_text, "test_required_names") != (
    "AWS_REPOSITORY",
    "AWS_ECS_CLUSTER",
    "AWS_ECS_SERVICE",
    "AWS_ECS_TASK_FAMILY",
    "AWS_ECS_CONTAINER_NAME",
    "AWS_ECS_PORTS",
    "AWS_ECS_READONLY_ROOTFILESYSTEM",
    "AWS_ECS_VOLUMES_EFS",
):
    fail("Versioned SSM regression must model the exact eight required deploy variables.")
if shell_array_values(versioned_ssm_test_text, "test_optional_names") != (
    "AWS_ECS_CONTAINER_MEMORY_RESERVATION",
    "AWS_ECS_CONTAINER_CPU",
    "AWS_ECS_FARGATE_CPU",
    "AWS_ECS_FARGATE_MEMORY",
):
    fail("Versioned SSM regression must model the exact four optional deploy variables.")
require_markers(
    versioned_ssm_test_text,
    (
        'wc -l < "${manifest_path}" | tr -d \' \')" = 13',
        "absent\\tAWS_ECS_FARGATE_MEMORY\\t-\\t-\\t-",
        'test "${AWS_ECS_VOLUMES_EFS}" = value-AWS_ECS_VOLUMES_EFS',
    ),
    "Exact twelve-variable versioned SSM regression",
)
for forbidden_versioned_fixture in (
    "AWS_ECS_VOLUMES",
    "AWS_ECS_CONTAINER_HEALTH_CMD",
    "AWS_ECS_CONTAINER_CMD",
):
    if re.search(
        rf"\b{re.escape(forbidden_versioned_fixture)}\b", versioned_ssm_test_text
    ):
        fail(
            "Versioned SSM regression must not model forbidden deploy input: "
            f"{forbidden_versioned_fixture}"
        )

for retired_origin_path in (
    REPOSITORY_ROOT / "src" / "includes" / "netlify.proxy.nginx.conf",
    REPOSITORY_ROOT / "scripts" / "validate-netlify-origin.sh",
    REPOSITORY_ROOT / "scripts" / "test-netlify-origin.sh",
    REPOSITORY_ROOT / "scripts" / "verify-netlify-origin-image.sh",
):
    if retired_origin_path.exists():
        fail(f"Retired origin support remains in provider-off tree: {retired_origin_path}")

dockerfile_text = DOCKERFILE_PATH.read_text(encoding="utf-8")
nginx_source_text = "\n".join(
    path.read_text(encoding="utf-8")
    for path in sorted(NGINX_SOURCE_ROOT.rglob("*"))
    if path.is_file()
)
build_script_text = BUILD_SCRIPT_PATH.read_text(encoding="utf-8")
require_markers(
    dockerfile_text,
    (
        "FROM ubuntu:noble@sha256:33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517",
        "apt-get install -y --no-install-recommends \\\n"
        "        ca-certificates \\\n"
        "        nginx \\\n"
        "    && rm -rf /var/lib/apt/lists/*",
        "chown -Rf www-data:www-data",
        "ARG SOURCE_COMMIT=local",
        'org.opencontainers.image.revision="${SOURCE_COMMIT}"',
        'CMD ["./rund"]',
    ),
    "Production image",
)
if dockerfile_text.count("apt-get install") != 1:
    fail("Production image must have exactly one runtime-only package install.")
for forbidden_build_dependency in (
    "apt-get upgrade",
    "software-properties-common",
    "add-apt-repository",
    "ppa:topcoder",
    "nginx-topcoder",
    "adduser",
):
    if forbidden_build_dependency in dockerfile_text:
        fail(
            "Production image must use only the supported Ubuntu nginx runtime: "
            f"{forbidden_build_dependency}"
        )
for forbidden_ajp_directive in ("ajp_pass", "ajp_header_packet_buffer_size"):
    if re.search(rf"\b{re.escape(forbidden_ajp_directive)}\b", nginx_source_text):
        fail(f"Unused custom AJP configuration remains: {forbidden_ajp_directive}")
require_markers(
    nginx_source_text,
    ("user www-data;",),
    "Ubuntu nginx worker identity",
)
if "COPY scripts /data/nginxconf/scripts" in dockerfile_text:
    fail("Production image must not contain CI, deployment, or test scripts.")
if "/data/nginxconf/scripts" in dockerfile_text:
    fail("Production image must not contain the ineffective cron reload scripts.")
if '--provenance=false --build-arg "SOURCE_COMMIT=${SOURCE_COMMIT}"' not in build_script_text:
    fail("Production build must bind the OCI revision label to CIRCLE_SHA1.")
require_markers(
    build_script_text,
    (
        "./scripts/test-configure-nonproduction-aws.sh",
        "./scripts/test-production-authority-gates.sh",
        "./scripts/test-configure-production-snapshot-aws.sh",
        "./scripts/test-production-snapshot-session-policy.sh",
        "./scripts/test-efs-mapping.sh",
        "./scripts/test-task-definition-contract.py",
        "./scripts/test-retired-provider-routes.sh",
        "./scripts/verify-no-retired-provider-routes.py dist",
        "readonly runtime_www_host='www.topcoder.com'",
        'readonly runtime_www_host="www.topcoder-${ENV}.com"',
        './scripts/test-runtime.sh "$TAG" "$runtime_www_host"',
        './scripts/verify-provider-off-image.sh "$TAG" "$SOURCE_COMMIT"',
    ),
    "Production image build",
)
if "ENV_NETLIFY" in build_script_text:
    fail("Provider-off build script still references the retired origin parameter.")
runtime_test_text = RUNTIME_TEST_PATH.read_text(encoding="utf-8")
require_markers(
    runtime_test_text,
    (
        "Usage: test-runtime.sh IMAGE [EXPECTED_WWW_HOST]",
        "docker exec",
        "/dev/tcp/127.0.0.1/8000",
        'readonly expected_www_host="${2:-www.topcoder.com}"',
        "GET /www_topcoder_status HTTP/1.0",
        'printf "Host: %s\\r\\n" "${expected_www_host}"',
        'bash "${expected_www_host}"',
        'printf "Host: %s\\r\\n" "$2"',
        "readonly -a fail_closed_routes",
        "'/api'",
        'readonly health_status_code',
        'if [[ "${health_status_code}" != 200 ]]',
        'if [[ "${route_status_code}" != 404 ]]',
        'docker rm --force "${container_name}"',
        "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25",
    ),
    "Remote-Docker-compatible live runtime regression",
)
if "--publish 127.0.0.1" in runtime_test_text:
    fail("Runtime HTTP probes must not assume Remote Docker loopback is local.")
runtime_cleanup_text = runtime_test_text.split("cleanup() {", 1)[1].split(
    "trap cleanup EXIT", 1
)[0]
post_force_removal_cleanup = runtime_cleanup_text.split(
    'docker rm --force "${container_name}"', 1
)[1]
require_markers(
    post_force_removal_cleanup,
    (
        'docker container inspect "${container_name}"',
        "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25",
    ),
    "Bounded Docker auto-remove cleanup",
)
runtime_entrypoint_text = RUNTIME_ENTRYPOINT_PATH.read_text(encoding="utf-8")
require_markers(
    runtime_entrypoint_text,
    (
        "set -euo pipefail",
        '${PROVIDER:-}',
        "/tmp/nginx/cache",
        "--owner=www-data --group=www-data",
        "nginx -t",
        "exec nginx",
    ),
    "Production runtime entrypoint",
)
for retired_runtime_path in (
    REPOSITORY_ROOT / "scripts" / "root.cron",
    REPOSITORY_ROOT / "scripts" / "nginx-HUP-from-container.sh",
):
    if retired_runtime_path.exists():
        fail(f"Retired runtime reload file remains: {retired_runtime_path}")
print(
    "Provider-off production artifact contract passed; AWS authority remains fail-closed "
    f"for {CONFIG_PATH}."
)
