# elektrine_chat_web

Dedicated Phoenix web/API app for chat and authentication.

This app exposes:
- `/api/auth/*` token auth endpoints
- `/api/servers`, `/api/conversations`, `/api/messages` chat APIs
- `/federation/messaging/*` signed federation endpoints
- `/socket` channel transport for real-time chat events

It is intended to power the `elektrine_chat_auth` release profile.
