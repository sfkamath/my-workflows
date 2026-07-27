#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [config-file] [--dry-run true|false]" >&2
}

config_file="config/secret-targets.json"
dry_run="true"

if [[ $# -gt 0 && $1 != --* ]]; then
  config_file=$1
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      dry_run=$2
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ $dry_run == "true" || $dry_run == "false" ]] || {
  echo "--dry-run must be true or false" >&2
  exit 2
}

for command in gh jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command not found: $command" >&2
    exit 1
  }
done

[[ -f $config_file ]] || {
  echo "Configuration file not found: $config_file" >&2
  exit 1
}

jq -e '
  (.mappings | type == "array") and
  all(
    .mappings[];
    ((.enabled // true) | type == "boolean") and
    (.source | type == "string" and length > 0) and
    ((.destination // .source) | type == "string" and length > 0) and
    (.repositories | type == "array" and length > 0 and
      all(.[]; type == "string" and test("^[^/]+/[^/]+$")))
  )
' "$config_file" >/dev/null || {
  echo "Invalid secret target configuration: $config_file" >&2
  exit 1
}

if [[ $dry_run == "false" ]]; then
  [[ -n ${SECRET_VALUES_JSON:-} ]] || {
    echo "SECRET_VALUES_JSON is required when dry-run is false" >&2
    exit 1
  }
  jq -e 'type == "object"' <<<"$SECRET_VALUES_JSON" >/dev/null || {
    echo "SECRET_VALUES_JSON must be a JSON object" >&2
    exit 1
  }
fi

updated=0
while IFS= read -r mapping; do
  source_name=$(jq -r '.source' <<<"$mapping")
  destination_name=$(jq -r '.destination // .source' <<<"$mapping")

  while IFS= read -r repository; do
    if [[ $dry_run == "true" ]]; then
      echo "DRY RUN: would set $destination_name in $repository from $source_name"
    else
      if ! value=$(jq -er --arg name "$source_name" '.[$name] | select(type == "string")' \
        <<<"$SECRET_VALUES_JSON"); then
        echo "No value found for $source_name in SECRET_VALUES_JSON" >&2
        exit 1
      fi
      printf '%s' "$value" | gh secret set "$destination_name" --repo "$repository"
      echo "Set $destination_name in $repository"
    fi
    ((updated += 1))
  done < <(jq -r '.repositories[]' <<<"$mapping")
done < <(jq -c '.mappings[] | select(.enabled // true)' "$config_file")

action="identified"
[[ $dry_run == "false" ]] && action="updated"
echo "Secret synchronization complete: $action $updated repository secrets."
