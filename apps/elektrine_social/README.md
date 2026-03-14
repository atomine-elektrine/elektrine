# Elektrine Social

Social domain and extracted social web surface for the Elektrine umbrella.

## What this app owns

- Timeline post creation and feed logic
- Likes, boosts/quotes, bookmarks, and view tracking
- Hashtags, lists, polls, and recommendations
- Link preview and social background jobs
- Extracted social web surfaces under `ElektrineWeb.*`
  including timeline/community/list/gallery/remote-profile LiveViews,
  authenticated and external social APIs, ActivityPub/WebFinger/NodeInfo,
  Mastodon compatibility endpoints, media proxying, and interaction redirects

## Notes

- Builds on shared messaging/accounts contexts from `elektrine`.
- Main API surface is `Elektrine.Social`.
- `elektrine_web` mounts these modules as the host shell and keeps shared
  layout/auth/navigation concerns.

## License

AGPL-3.0-only (see `../../LICENSE`).
