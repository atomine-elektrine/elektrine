# Warrant Canary Maintenance

Elektrine serves warrant canary materials from `apps/elektrine_web/priv/canary`:

- `current.md` is the current statement.
- `current.md.asc` is the detached signature for `current.md`.
- `canary-public-key.asc` is the public signing key.

Public routes:

- `/canary`
- `/canary/current.md`
- `/canary/current.md.asc`
- `/canary-key.asc`

## Process

1. Copy the previous canary statement.
2. Update `Published`, `Valid until`, recent public references, and any wording that intentionally changed.
3. Verify the signing key fingerprint in the statement matches the public key.
4. Sign the statement:

```bash
gpg --armor --detach-sign current.md
```

5. Replace `current.md` and `current.md.asc` in `apps/elektrine_web/priv/canary`.
6. Verify the published files after deploy:

```bash
curl -fsS https://your-domain.example/canary/current.md -o current.md
curl -fsS https://your-domain.example/canary/current.md.asc -o current.md.asc
curl -fsS https://your-domain.example/canary-key.asc -o canary-public-key.asc
gpg --import canary-public-key.asc
gpg --verify current.md.asc current.md
```

Do not silently edit old signed statements. Publish a corrected new statement if needed.
