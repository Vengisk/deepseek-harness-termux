#!/usr/bin/env bash
# dsh launcher for the prebuilt Termux deployment (Plan B).
#
# The postinstall of dsh-termux deploys the patched @deepseek-ai/dsh into the
# npm global root; this launcher resolves that deployment and boots it with
# --expose-internals (required by the HMR plugin).
set -euo pipefail

# bin/dsh -> <globalRoot>/lib/node_modules/dsh-termux/bin/dsh
# We need <globalRoot>/node_modules/@deepseek-ai/dsh/lib/bin.js
NODE_MODULES="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"

exec node --expose-internals "$NODE_MODULES/@deepseek-ai/dsh/lib/bin.js" "$@"
