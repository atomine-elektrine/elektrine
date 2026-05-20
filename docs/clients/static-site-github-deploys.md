# Static Site GitHub Deploys

Elektrine can deploy committed static output from a linked GitHub repository.

In `Account > Profile Edit > Publish`, connect GitHub, enter the repo and branch, then link it. Elektrine auto-detects `dist`, `build`, `public`, `out`, `zig-out`, or the repo root.

Each deploy replaces the currently published static site files.

Manual PAT deploy remains available:

```bash
curl --fail-with-body \
  --request POST "https://elektrine.example.com/api/ext/v1/static-site/deploy" \
  --header "Authorization: Bearer $ELEKTRINE_STATIC_SITE_TOKEN" \
  --form "replace=true" \
  --form "site=@site.zip;type=application/zip"
```
