# Repository automation configuration

## Package retention

`package-retention.json` controls the scheduled package sweep.

- `owner_type` is `user` or `org`.
- `package_types` may contain `container`, `maven`, `npm`, `nuget`, or
  `rubygems`.
- `defaults.keep` is the normal number of newest, unprotected versions to keep.
- When a package contains more than `threshold_versions`,
  `threshold_keep` replaces `keep`.
- An override matches one package by exact `type` and `name`. Its values replace
  the corresponding defaults.
- Versions whose name or container tag matches a protected regular expression
  are never deleted and do not consume the `keep` allowance.
- The committed policy has `dry_run` enabled. Set it to `false` only after
  reviewing a dry-run workflow result. A manual workflow run can override it.

The workflow requires a `PACKAGE_SWEEP_TOKEN` Actions secret. For an account-wide
sweep, use a classic personal access token with `read:packages` and
`delete:packages`; include `repo` when private packages are linked to private
repositories. The token's user must have admin access to the packages.

## Secret synchronization

`secret-targets.json` maps a logical source name to a destination secret name and
an explicit list of `owner/repository` targets. Disabled mappings are ignored.

Secret values cannot be read back from GitHub. Store the source values in the
`SECRET_VALUES_JSON` Actions secret as one JSON object:

```json
{
  "EXAMPLE_SHARED_SECRET": "the-value-to-distribute"
}
```

The workflow also requires a `SECRET_SYNC_TOKEN` Actions secret. A classic
personal access token needs `repo` for private target repositories and
`public_repo` for public-only targets. A fine-grained token needs repository
`Secrets` write permission on every target repository.

Secret synchronization is manual and defaults to dry-run. Enable a mapping,
review a dry run, and then dispatch it with `dry_run` disabled.
