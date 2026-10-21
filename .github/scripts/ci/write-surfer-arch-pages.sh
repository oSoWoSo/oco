#!/usr/bin/env bash
set -euo pipefail

DESTINATION=${DESTINATION:-}
if [[ $DESTINATION == testing ]]; then export SURF_PATH_PREFIX=testing; else export SURF_PATH_PREFIX=''; fi
(cd extra && ./ocoman -a)
