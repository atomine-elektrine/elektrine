# Elektrine Social

Social domain code and social web routes for the Elektrine umbrella.

## What lives here

- Timeline post creation and feed logic
- Likes, boosts/quotes, bookmarks, and view tracking
- Hashtags, lists, polls, and recommendations
- Link preview and social background jobs
- Timeline, community, list, gallery, hashtag, and remote-profile LiveViews
- Social APIs, ActivityPub/WebFinger/NodeInfo, Mastodon compatibility endpoints, media proxying, and interaction redirects
- Social components primarily under `ElektrineSocialWeb.Components.Social.*`, with a small set of shared helpers still under `ElektrineWeb.Components.Social.*` (post utilities, reactions, fediverse follow, YouTube preview)

## Notes

- Builds on shared messaging/accounts contexts from `elektrine`.
- Main domain API is `Elektrine.Social`.
- `elektrine_web` mounts these modules and keeps shared layout/auth/navigation concerns.
- Router-mounted modules in this app still use `ElektrineWeb.*`; extracted social entrypoints live in `ElektrineSocialWeb`.

## License

AGPL-3.0-only (see `../../LICENSE`).
