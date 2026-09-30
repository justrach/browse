#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp/}browse-tasks.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 -parse-as-library Sources/Browse/AgentTasks.swift tests/agent-tasks/main.swift -o "$SCRATCH/tasks"
"$SCRATCH/tasks"
