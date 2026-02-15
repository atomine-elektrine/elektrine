# Umbrella Apps

Elektrine is organized as an Elixir umbrella project.

## Apps

- [`elektrine`](./elektrine/README.md) - Core domain logic, persistence, runtime services
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
mix test apps/elektrine_email/test
mix test apps/elektrine_social/test
mix test apps/elektrine_vpn/test
mix test apps/elektrine_password_manager/test
```

## License

All umbrella apps are covered by the root repository `LICENSE`.
