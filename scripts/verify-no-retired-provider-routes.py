#!/usr/bin/env python3
"""Reject retired hosting or CMS targets from deployment inputs."""

from __future__ import annotations

import base64
import binascii
import html
import re
import sys
from pathlib import Path
from urllib.parse import unquote


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TARGETS = (
    REPOSITORY_ROOT / "src",
    REPOSITORY_ROOT / ".circleci" / "config.yml",
    REPOSITORY_ROOT / ".dockerignore",
    REPOSITORY_ROOT / "Dockerfile",
    REPOSITORY_ROOT / "ECSDockerfile",
    REPOSITORY_ROOT / "appspec.yml",
    REPOSITORY_ROOT / "build",
    REPOSITORY_ROOT / "buildimage.sh",
    REPOSITORY_ROOT / "deploy.sh",
    REPOSITORY_ROOT / "healthcheck.html",
    REPOSITORY_ROOT / "local",
    REPOSITORY_ROOT / "locald",
    REPOSITORY_ROOT / "run",
    REPOSITORY_ROOT / "rund",
    REPOSITORY_ROOT / "supply-ops.nginx.stack.json",
    REPOSITORY_ROOT / "scripts" / "nginx-HUP-from-host.sh",
    REPOSITORY_ROOT / "scripts" / "start_server",
    REPOSITORY_ROOT / "scripts" / "stop_server",
    REPOSITORY_ROOT / "scripts" / "test_server",
)
RETIRED_MARKERS = {
    "netlify": "retired hosting provider",
    "contentful": "retired CMS provider",
    "ctfassetsnet": "retired CMS asset host",
    "octana": "retired proxy provider",
}
UNICODE_ESCAPE = re.compile(r"\\u([0-9a-fA-F]{4})")
HEX_ESCAPE = re.compile(r"\\x([0-9a-fA-F]{2})")
NON_ALPHANUMERIC = re.compile(r"[^a-z0-9]+")
BASE64_TOKEN = re.compile(r"(?<![A-Za-z0-9+/_=-])([A-Za-z0-9+/_-]{12,}={0,2})(?![A-Za-z0-9+/_=-])")
NGINX_SET_DIRECTIVE = re.compile(
    r"\bset\s+\$([A-Za-z_][A-Za-z0-9_]*)\s+([^;]+);",
    re.MULTILINE,
)
NGINX_PROXY_PASS_DIRECTIVE = re.compile(r"\bproxy_pass\s+([^;]+);", re.MULTILINE)
NGINX_VARIABLE = re.compile(
    r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))"
)


def decode_obfuscation(value: str) -> str:
    """Decode common representations used to disguise a provider literal.

    Args:
        value: File name or text to normalize.

    Returns:
        Text after repeated HTML, URL, Unicode, and hex decoding.
    """

    decoded = value
    for _ in range(3):
        updated = html.unescape(unquote(decoded))
        updated = UNICODE_ESCAPE.sub(lambda match: chr(int(match.group(1), 16)), updated)
        updated = HEX_ESCAPE.sub(lambda match: chr(int(match.group(1), 16)), updated)
        if updated == decoded:
            break
        decoded = updated
    return decoded


def canonicalize(value: str) -> str:
    """Collapse punctuation so split literals and variable names are detectable.

    Args:
        value: Decoded or encoded text to canonicalize.

    Returns:
        Lowercase ASCII-alphanumeric text suitable for marker matching.
    """

    return NON_ALPHANUMERIC.sub("", decode_obfuscation(value).lower())


def expanded_encoded_values(value: str) -> list[str]:
    """Expand printable base64 tokens so encoded deployment values are scanned.

    Args:
        value: Source text which may contain standard or URL-safe base64 tokens.

    Returns:
        The original value plus recursively decoded printable UTF-8 values.
    """

    values = [value]
    seen = {value}
    frontier = [value]
    for _ in range(3):
        next_frontier: list[str] = []
        for candidate in frontier:
            for match in BASE64_TOKEN.finditer(candidate):
                token = match.group(1)
                if len(token) % 4 == 1:
                    continue
                padded = token + "=" * (-len(token) % 4)
                try:
                    decoded_bytes = base64.b64decode(
                        padded,
                        altchars=b"-_",
                        validate=True,
                    )
                    decoded = decoded_bytes.decode("utf-8")
                except (binascii.Error, UnicodeDecodeError, ValueError):
                    continue
                if not decoded or any(
                    ord(character) < 32 and character not in "\t\r\n"
                    for character in decoded
                ):
                    continue
                if decoded not in seen:
                    seen.add(decoded)
                    values.append(decoded)
                    next_frontier.append(decoded)
        frontier = next_frontier
        if not frontier:
            break
    return values


def resolved_nginx_values(text: str) -> list[tuple[str, str]]:
    """Resolve simple nginx ``set`` graphs used by dynamic proxy destinations.

    Args:
        text: Nginx or deployment text to inspect.

    Returns:
        Named resolved assignment and ``proxy_pass`` values for marker scanning.
    """

    assignments = {
        name: raw_value.strip()
        for name, raw_value in NGINX_SET_DIRECTIVE.findall(text)
    }
    cache: dict[str, str] = {}

    def resolve_variable(name: str, resolving: set[str]) -> str:
        if name in cache:
            return cache[name]
        if name not in assignments or name in resolving:
            return f"${{{name}}}"
        resolving.add(name)
        resolved = NGINX_VARIABLE.sub(
            lambda match: resolve_variable(
                match.group(1) or match.group(2),
                resolving,
            ),
            assignments[name],
        )
        resolving.remove(name)
        cache[name] = resolved
        return resolved

    values = [
        (f"resolved nginx variable ${name}", resolve_variable(name, set()))
        for name in assignments
    ]
    for index, raw_value in enumerate(NGINX_PROXY_PASS_DIRECTIVE.findall(text), 1):
        resolved = NGINX_VARIABLE.sub(
            lambda match: resolve_variable(match.group(1) or match.group(2), set()),
            raw_value.strip(),
        )
        values.append((f"resolved proxy_pass {index}", resolved))
    return values


def files_under(target: Path) -> list[Path]:
    """Resolve one scan target into deterministic regular files.

    Args:
        target: Existing file or directory to scan.

    Returns:
        The target file, or all regular files recursively below a directory.

    Raises:
        FileNotFoundError: The requested deployment input does not exist.
    """

    if target.is_file():
        return [target]
    if target.is_dir():
        return sorted(path for path in target.rglob("*") if path.is_file())
    raise FileNotFoundError(f"scan target does not exist: {target}")


def relative_name(path: Path) -> str:
    """Format a path consistently for provider-scan evidence.

    Args:
        path: Scanned path to display.

    Returns:
        Repository-relative text when possible, otherwise the absolute path.
    """

    try:
        return str(path.relative_to(REPOSITORY_ROOT))
    except ValueError:
        return str(path)


def scan_text(display_name: str, text: str) -> list[str]:
    """Find retired provider markers in deployment text.

    Args:
        display_name: Stable source name for findings.
        text: Source content to inspect.

    Returns:
        Sorted, de-duplicated findings with path and source context.

    """

    values = [("path", display_name), ("combined content", text)]
    values.extend(
        (f"line {line_number}", line)
        for line_number, line in enumerate(text.splitlines(), 1)
    )
    values.extend(resolved_nginx_values(text))
    findings: set[str] = set()
    for source, value in values:
        for expanded_value in expanded_encoded_values(value):
            canonical = canonicalize(expanded_value)
            for marker, description in RETIRED_MARKERS.items():
                if marker in canonical:
                    findings.add(f"{display_name}: {source} contains {description}")
    return sorted(findings)


def scan_file(path: Path) -> list[str]:
    """Find retired provider markers in a deployment input file.

    Args:
        path: Regular file whose name and content should be inspected.

    Returns:
        Sorted, de-duplicated findings with path and source context.

    Raises:
        OSError: The input cannot be read.
        UnicodeError: Text normalization fails.
    """

    display_name = relative_name(path)
    return scan_text(display_name, path.read_text(errors="replace"))


def main(arguments: list[str]) -> int:
    """Scan requested or default deployment inputs and report findings.

    Args:
        arguments: Optional file or directory paths supplied on the command line.

    Returns:
        Zero when no target is found, one for findings, or two for scan errors.
    """

    requested_targets = arguments if arguments else [str(target) for target in DEFAULT_TARGETS]
    findings: list[str] = []
    scanned_files = 0
    stdin_consumed = False
    try:
        for requested_target in requested_targets:
            if requested_target == "-":
                if stdin_consumed:
                    raise OSError("standard input may be scanned only once")
                stdin_consumed = True
                findings.extend(scan_text("<stdin>", sys.stdin.read()))
                scanned_files += 1
                continue
            target = Path(requested_target).resolve()
            files = files_under(target)
            scanned_files += len(files)
            for path in files:
                findings.extend(scan_file(path))
    except (OSError, UnicodeError) as error:
        print(f"Retired-provider route scan failed: {error}", file=sys.stderr)
        return 2

    if findings:
        print("Retired-provider route scan failed:", file=sys.stderr)
        for finding in findings:
            print(f"- {finding}", file=sys.stderr)
        return 1

    print(f"Retired-provider route scan passed ({scanned_files} file(s)).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
