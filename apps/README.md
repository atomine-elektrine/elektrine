# Umbrella Apps

Elektrine is organized as an Elixir umbrella project.

## Apps

- [`elektrine`](./elektrine/README.md) - Core domain logic, persistence, runtime services
- [`elektrine_web`](./elektrine_web/README.md) - Phoenix endpoint, router, shared layout, and common components
- [`elektrine_chat`](./elektrine_chat/README.md) - Chat facade, LiveViews, JSON APIs, and PAT APIs
- [`elektrine_email`](./elektrine_email/README.md) - Mailbox domain, mail protocols, JMAP, WKD, and web routes
- [`elektrine_social`](./elektrine_social/README.md) - Social/timeline features
- [`elektrine_vpn`](./elektrine_vpn/README.md) - VPN features
- [`elektrine_password_manager`](./elektrine_password_manager/README.md) - Password vault domain and route macros
- [`elektrine_dns`](./elektrine_dns/README.md) - Managed DNS runtime, PAT API, and DNS LiveViews

## Running app-focused tests

From the umbrella root:

```bash
mix test apps/elektrine/test
mix test apps/elektrine_web/test
mix test apps/elektrine_email/test
mix test apps/elektrine_social/test
mix test apps/elektrine_vpn/test
mix test apps/elektrine_password_manager/test
mix test apps/elektrine_dns/test
```

## Protocol docs

The current Arblarg messaging federation spec lives at `../docs/arblarg-1.0.md`.

## License

All umbrella apps are covered by the root repository `LICENSE`.
