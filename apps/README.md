# Umbrella Apps

Elektrine is organized as an Elixir umbrella project.

## Apps

- [`elektrine`](./elektrine/README.md) - Core domain logic, persistence, runtime services
- [`elektrine_chat`](./elektrine_chat/README.md) - Chat app boundary and messaging facade
- [`elektrine_chat_web`](./elektrine_chat_web/README.md) - Dedicated chat/auth API endpoint + channels
- [`elektrine_web`](./elektrine_web/README.md) - Web endpoint, controllers, LiveView UI
- [`elektrine_email`](./elektrine_email/README.md) - Email features and protocols
- [`elektrine_social`](./elektrine_social/README.md) - Social/timeline features
- [`elektrine_vpn`](./elektrine_vpn/README.md) - VPN features
- [`elektrine_password_manager`](./elektrine_password_manager/README.md) - Password manager module

## Running app-focused tests

From the umbrella root:

```bash
mix test apps/elektrine/test
mix test apps/elektrine_web/test
mix test apps/elektrine_chat_web/test
mix test apps/elektrine_email/test
mix test apps/elektrine_social/test
mix test apps/elektrine_vpn/test
mix test apps/elektrine_password_manager/test
```

## Chat/Auth-only release

Use `MIX_ENV=prod mix release elektrine_chat_auth` to produce a release focused on chat + auth.
See `../CHAT_AUTH_SELF_HOSTING.md` for details.

## License

All umbrella apps are covered by the root repository `LICENSE`.
