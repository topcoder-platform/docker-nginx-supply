#!/usr/bin/env python3
"""Pass the reviewed manifest and this job's prebuilt images to the pinned suite."""
import json
from pathlib import Path
import subprocess
import sys

manifest = Path(sys.argv[1])
data = json.loads(manifest.read_text())
if data['environment'] == 'dev':
    raise SystemExit('Verify dev public build configuration and select its build target before enabling dev deployment')
command = [sys.executable, '-I', '/tmp/tc-deploy-scripts/tcdeploy.py', 'deploy', '--manifest', str(manifest)]
for container in data['images']:
    command.extend(['--image', container + '=docker-nginx-supply:candidate'])
subprocess.run(command, check=True)
