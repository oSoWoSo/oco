#!/usr/bin/env bash
set -euo pipefail

DESTINATION=${DESTINATION:-}
if [[ $DESTINATION == testing ]]; then
  export SURF_PATH_PREFIX=testing
  export OCO_SITE_BRANCH=testing
else
  export SURF_PATH_PREFIX=''
  export OCO_SITE_BRANCH=OCO
fi
(cd extra && ./ocoman -a)
