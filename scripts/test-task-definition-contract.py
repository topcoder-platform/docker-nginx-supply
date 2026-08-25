#!/usr/bin/env python3
"""Exercise the exact jq task-definition assertion embedded in CircleCI."""

from __future__ import annotations

import copy
import json
import subprocess
from pathlib import Path
from typing import Any, Callable

import yaml


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = REPOSITORY_ROOT / ".circleci" / "config.yml"
FILTER_START = '--arg expected_fargate_memory "${expected_fargate_memory}" \'\n'
FILTER_END = '\n    \' \\<<< "${task_definition_response}"'


def fail(message: str) -> None:
    raise SystemExit(message)


config = yaml.safe_load(CONFIG_PATH.read_text(encoding="utf-8"))
try:
    deploy_steps = config["jobs"]["deploy-prod"]["steps"]
except (KeyError, TypeError) as error:
    raise SystemExit("Production deploy steps are missing.") from error

commands = "\n".join(
    value["command"]
    for step in deploy_steps
    if isinstance(step, dict)
    for value in step.values()
    if isinstance(value, dict) and isinstance(value.get("command"), str)
)
try:
    filter_start = commands.index(FILTER_START) + len(FILTER_START)
    filter_end = commands.index(FILTER_END, filter_start)
except ValueError as error:
    raise SystemExit("The exact production task-definition jq assertion is missing.") from error
jq_filter = commands[filter_start:filter_end]

expected_ports = [
    {"hostPort": 8000, "containerPort": 8000, "protocol": "tcp"},
    {"hostPort": 9000, "containerPort": 9000, "protocol": "udp"},
]
jq_arguments = [
    "jq",
    "-e",
    "--arg",
    "family",
    "supply",
    "--arg",
    "container",
    "supply",
    "--arg",
    "image",
    "image@sha256:approved",
    "--arg",
    "execution_role",
    "arn:aws:iam::409275337247:role/ecsTaskExecutionRole",
    "--arg",
    "efs_volume_name",
    "legacy-content",
    "--arg",
    "efs_root_directory",
    "/published",
    "--arg",
    "efs_container_path",
    "/data/nginx",
    "--arg",
    "efs_filesystem_id",
    "fs-0123456789abcdef0",
    "--argjson",
    "expected_port_mappings",
    json.dumps(expected_ports, separators=(",", ":")),
    "--arg",
    "expected_container_memory_reservation",
    "1000",
    "--arg",
    "expected_container_cpu",
    "100",
    "--arg",
    "expected_fargate_cpu",
    "1024",
    "--arg",
    "expected_fargate_memory",
    "2048",
    jq_filter,
]

valid_task: dict[str, Any] = {
    "taskDefinition": {
        "family": "supply",
        "networkMode": "awsvpc",
        "requiresCompatibilities": ["FARGATE"],
        "executionRoleArn": "arn:aws:iam::409275337247:role/ecsTaskExecutionRole",
        "cpu": "1024",
        "memory": "2048",
        "volumes": [
            {
                "name": "legacy-content",
                "efsVolumeConfiguration": {
                    "fileSystemId": "fs-0123456789abcdef0",
                    "rootDirectory": "/published",
                },
            }
        ],
        "containerDefinitions": [
            {
                "name": "supply",
                "image": "image@sha256:approved",
                "essential": True,
                "memoryReservation": 1000,
                "cpu": 100,
                # ECS ordering is not approval-significant; the jq contract normalizes it.
                "portMappings": list(reversed(expected_ports)),
                "readonlyRootFilesystem": False,
                "mountPoints": [
                    {
                        "sourceVolume": "legacy-content",
                        "containerPath": "/data/nginx",
                    }
                ],
            }
        ],
    }
}


def accepted(task: dict[str, Any]) -> bool:
    result = subprocess.run(
        jq_arguments,
        input=json.dumps(task),
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    )
    return result.returncode == 0


if not accepted(valid_task):
    fail("The task-definition assertion rejected the exact approved fixture.")


def add_sidecar(task: dict[str, Any]) -> None:
    task["taskDefinition"]["containerDefinitions"].append({"name": "sidecar"})


def drift_port(task: dict[str, Any]) -> None:
    task["taskDefinition"]["containerDefinitions"][0]["portMappings"][0][
        "hostPort"
    ] = 9001


def drift_container_cpu(task: dict[str, Any]) -> None:
    task["taskDefinition"]["containerDefinitions"][0]["cpu"] = 200


def drift_task_memory(task: dict[str, Any]) -> None:
    task["taskDefinition"]["memory"] = "4096"


def inject_secret(task: dict[str, Any]) -> None:
    task["taskDefinition"]["containerDefinitions"][0]["secrets"] = [
        {"name": "UNEXPECTED", "valueFrom": "unapproved"}
    ]


def drift_efs(task: dict[str, Any]) -> None:
    task["taskDefinition"]["volumes"][0]["efsVolumeConfiguration"][
        "rootDirectory"
    ] = "/other"


negative_cases: tuple[tuple[str, Callable[[dict[str, Any]], None]], ...] = (
    ("sidecar", add_sidecar),
    ("port drift", drift_port),
    ("container CPU drift", drift_container_cpu),
    ("task memory drift", drift_task_memory),
    ("secret injection", inject_secret),
    ("EFS drift", drift_efs),
)
for label, mutate in negative_cases:
    candidate = copy.deepcopy(valid_task)
    mutate(candidate)
    if accepted(candidate):
        fail(f"The task-definition assertion accepted {label}.")

print("Exact ECS task-definition assertion regression passed.")
