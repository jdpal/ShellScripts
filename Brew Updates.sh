#!/bin/bash

# === Log setup ===
LOG_DIR="$HOME/MyApp_Logs"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/BrewUpdate_success.log") 2> >(tee -a "$LOG_DIR/BrewUpdate_error.log" >&2)

# For formulae
brew list --formula --versions | while read -r formula version; do
  latest=$(brew info --formula --json=v2 "$formula" | jq -r '.formulae[0].versions.stable')
  [[ "$version" == "$latest" ]] && echo "$formula $version ✅" || echo "$formula $version ❌ (latest: $latest)"
done

# For casks
brew list --cask --versions | while read -r cask version; do
  latest=$(brew info --cask --json=v2 "$cask" | jq -r '.casks[0].version')
  [[ "$version" == "$latest" ]] && echo "$cask $version ✅" || echo "$cask $version ❌ (latest: $latest)"
done
