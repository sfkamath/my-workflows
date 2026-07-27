#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [config-file] [--dry-run true|false]" >&2
}

config_file="config/package-retention.json"
dry_run_override=""

if [[ $# -gt 0 && $1 != --* ]]; then
  config_file=$1
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      dry_run_override=$2
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

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
  (.owner | type == "string" and length > 0) and
  (.owner_type == "user" or .owner_type == "org") and
  (.package_types | type == "array" and length > 0 and all(.[]; IN("container", "maven", "npm", "nuget", "rubygems"))) and
  (.dry_run | type == "boolean") and
  (.defaults.keep | type == "number" and . >= 0 and floor == .) and
  (.defaults.threshold_versions | type == "number" and . >= 0 and floor == .) and
  (.defaults.threshold_keep | type == "number" and . >= 0 and floor == .) and
  (.defaults.protected_patterns | type == "array" and
    all(.[]; . as $pattern |
      type == "string" and (try ("" | test($pattern) | true) catch false))) and
  ((.overrides // []) | type == "array" and all(
    .[];
    (.type | IN("container", "maven", "npm", "nuget", "rubygems")) and
    (.name | type == "string" and length > 0) and
    ((.keep // 0) | type == "number" and . >= 0 and floor == .) and
    ((.threshold_versions // 0) | type == "number" and . >= 0 and floor == .) and
    ((.threshold_keep // 0) | type == "number" and . >= 0 and floor == .) and
    ((.protected_patterns // []) | type == "array" and
      all(.[]; . as $pattern |
        type == "string" and (try ("" | test($pattern) | true) catch false)))
  ))
' "$config_file" >/dev/null || {
  echo "Invalid package retention configuration: $config_file" >&2
  exit 1
}

owner=$(jq -r '.owner' "$config_file")
owner_type=$(jq -r '.owner_type' "$config_file")
dry_run=$(jq -r '.dry_run' "$config_file")

if [[ -n $dry_run_override ]]; then
  [[ $dry_run_override == "true" || $dry_run_override == "false" ]] || {
    echo "--dry-run must be true or false" >&2
    exit 2
  }
  dry_run=$dry_run_override
fi

if [[ $owner_type == "org" ]]; then
  packages_base="/orgs/$owner/packages"
else
  packages_base="/users/$owner/packages"
fi

deleted=0
inspected=0

while IFS= read -r package_type; do
  packages_json=$(gh api --paginate --slurp \
    "$packages_base?package_type=$package_type&per_page=100" | jq 'add // []')

  while IFS= read -r package_name; do
    encoded_name=$(jq -rn --arg value "$package_name" '$value | @uri')
    versions_json=$(gh api --paginate --slurp \
      "$packages_base/$package_type/$encoded_name/versions?per_page=100" | jq 'add // []')
    version_count=$(jq 'length' <<<"$versions_json")

    policy=$(jq -c \
      --arg type "$package_type" \
      --arg name "$package_name" '
        .defaults as $defaults |
        (first(.overrides[]? | select(.type == $type and .name == $name)) // {}) as $override |
        {
          keep: ($override.keep // $defaults.keep),
          threshold_versions: ($override.threshold_versions // $defaults.threshold_versions),
          threshold_keep: ($override.threshold_keep // $defaults.threshold_keep),
          protected_patterns: (
            $defaults.protected_patterns + ($override.protected_patterns // [])
          )
        }
      ' "$config_file")

    keep=$(jq -r '.keep' <<<"$policy")
    threshold_versions=$(jq -r '.threshold_versions' <<<"$policy")
    if (( version_count > threshold_versions )); then
      keep=$(jq -r '.threshold_keep' <<<"$policy")
    fi
    protected_patterns=$(jq -c '.protected_patterns' <<<"$policy")

    echo "$package_type/$package_name: $version_count versions; retaining latest $keep unprotected versions plus protected versions"

    deletion_candidates=$(jq -c \
      --argjson keep "$keep" \
      --argjson patterns "$protected_patterns" '
        def is_protected:
          . as $version |
          any(
            $patterns[];
            . as $pattern |
            ([$version.name, ($version.metadata.container.tags[]?)] |
              any(.[]; test($pattern)))
          );
        sort_by(.created_at // .updated_at) | reverse |
        map(. + {protected: is_protected}) |
        ([.[] | select(.protected)] | map(.id)) as $protected_ids |
        ([.[] | select(.protected | not)] | .[$keep:] | map(.id)) as $expired_ids |
        .[] | select(.id as $id | $expired_ids | index($id)) |
        {id, name, created_at, protected: (.id as $id | $protected_ids | index($id) != null)}
      ' <<<"$versions_json")

    while IFS= read -r version; do
      [[ -n $version ]] || continue
      version_id=$(jq -r '.id' <<<"$version")
      version_name=$(jq -r '.name' <<<"$version")
      created_at=$(jq -r '.created_at // "unknown"' <<<"$version")

      if [[ $dry_run == "true" ]]; then
        echo "  DRY RUN: would delete version $version_name ($version_id), created $created_at"
      else
        gh api --method DELETE \
          "$packages_base/$package_type/$encoded_name/versions/$version_id"
        echo "  Deleted version $version_name ($version_id), created $created_at"
      fi
      ((deleted += 1))
    done <<<"$deletion_candidates"

    ((inspected += version_count))
  done < <(jq -r '.[].name' <<<"$packages_json")
done < <(jq -r '.package_types[]' "$config_file")

action="identified"
[[ $dry_run == "false" ]] && action="deleted"
echo "Package sweep complete: $action $deleted expired versions after inspecting $inspected versions."
