# Elektrine Web

Phoenix web interface app for the Elektrine umbrella.

## What lives here

- Endpoint, router, plugs, channels, and API controllers
- Shared layouts, auth, navigation, and web components
- Host-shell LiveViews such as settings, profile, admin, files, storage, calendar, and search
- Web adapters for ActivityPub, messaging federation, DAV, OIDC, and other shared endpoints

## Notes

- Depends on `elektrine` and feature apps in the umbrella.
- Not every feature surface has been moved out yet. Some product-specific controllers and LiveViews still compile under `ElektrineWeb.*` for router compatibility.
- Templates, components, and LiveViews live under `apps/elektrine_web/lib/elektrine_web`.

## License

AGPL-3.0-only (see `../../LICENSE`).
