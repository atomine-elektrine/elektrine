#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

failures=0

check_max_lines() {
  local path="$1"
  local max_lines="$2"

  if [[ ! -f "$path" ]]; then
    echo "error: maintainability budget path does not exist: $path" >&2
    failures=$((failures + 1))
    return
  fi

  local lines
  lines=$(wc -l <"$path")

  if ((lines > max_lines)); then
    echo "error: $path has $lines lines; budget is $max_lines" >&2
    failures=$((failures + 1))
  fi
}

check_max_lines_matching() {
  local glob="$1"
  local max_lines="$2"
  local matched=0

  for path in $glob; do
    [[ -e "$path" ]] || continue
    matched=1
    check_max_lines "$path" "$max_lines"
  done

  if ((matched == 0)); then
    echo "error: maintainability budget glob matched no files: $glob" >&2
    failures=$((failures + 1))
  fi
}

# These budgets are intentionally set near the current hotspots. They prevent
# the largest files from growing while gradual extraction continues.
check_max_lines config/runtime.exs 1210
check_max_lines config/runtime/bluesky.exs 75
check_max_lines config/runtime/dns.exs 250
check_max_lines config/runtime/messaging_federation.exs 125
check_max_lines config/runtime/uploads.exs 100
check_max_lines config/runtime/webrtc.exs 125
check_max_lines apps/elektrine/priv/repo/seeds.exs 2700
check_max_lines_matching "apps/*/priv/repo/migrations/*.exs" 350
check_max_lines apps/elektrine/lib/elektrine/activitypub.ex 2275
check_max_lines apps/elektrine/lib/elektrine/activitypub/local_references.ex 300
check_max_lines apps/elektrine/lib/elektrine/activitypub/normalizer.ex 1400
check_max_lines apps/elektrine_social/lib/elektrine_social_web/controllers/activitypub_controller.ex 1325
check_max_lines apps/elektrine_social/lib/elektrine_social_web/controllers/activitypub/actor_request.ex 150
check_max_lines_matching "apps/elektrine/lib/elektrine/messaging/federation/*.ex" 1650
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/show.ex 5895
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/access_policy.ex 125
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/cached_post_fields.ex 375
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/navigation.ex 125
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/counts.ex 175
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/polls.ex 100
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/submitted_links.ex 300
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/detail_state.ex 400
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/detail_components.ex 200
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/ancestor_context_components.ex 300
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/threaded_comment_components.ex 1050
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/quick_reply_components.ex 400
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/reply_author_components.ex 300
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/discussions_live/index.ex 3800
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/discussions_live/session_context.ex 275
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_user_live/show.ex 600
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_user_live/actor_lookup.ex 100
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_user_live/community_post_operations.ex 200
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_user_live/counts.ex 300
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_user_live/follow_operations.ex 125
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_user_live/post_interaction_operations.ex 1125
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_user_live/post_sorting.ex 250
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_user_live/post_state.ex 450
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_user_live/reaction_surfaces.ex 175
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_user_live/reply_operations.ex 175
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_user_live/timeline_loader.ex 525
check_max_lines apps/elektrine_social/lib/elektrine/social.ex 1905
check_max_lines apps/elektrine_social/lib/elektrine/social/cross_posting.ex 400
check_max_lines apps/elektrine_social/lib/elektrine/social/discussions.ex 375
check_max_lines apps/elektrine_social/lib/elektrine/social/federated_feeds.ex 475
check_max_lines apps/elektrine_social/lib/elektrine/social/feed_query.ex 270
check_max_lines apps/elektrine_social/lib/elektrine/social/hashtags.ex 175
check_max_lines apps/elektrine_social/lib/elektrine/social/media_attachments.ex 425
check_max_lines apps/elektrine_social/lib/elektrine/social/polls.ex 475
check_max_lines apps/elektrine_social/lib/elektrine/social/status_reactions.ex 125
check_max_lines apps/elektrine_social/lib/elektrine/social/suggested_follows.ex 175
check_max_lines apps/elektrine_web/lib/elektrine_web/live/portal_live/index.ex 2970
check_max_lines apps/elektrine_web/lib/elektrine_web/live/portal_live/activity_inspector.ex 450
check_max_lines apps/elektrine_web/lib/elektrine_web/live/portal_live/attention.ex 375
check_max_lines apps/elektrine_web/lib/elektrine_web/live/portal_live/dashboard_data.ex 250
check_max_lines apps/elektrine_web/lib/elektrine_web/live/portal_live/recent_activity.ex 225
check_max_lines apps/elektrine_web/lib/elektrine_web/live/portal_live/session_context.ex 225
check_max_lines apps/elektrine_social/lib/elektrine_social_web/components/social/timeline_post.ex 2700
check_max_lines apps/elektrine_social/lib/elektrine_social_web/components/social/timeline_post_ancestors.ex 800
check_max_lines apps/elektrine_social/lib/elektrine_social_web/components/social/timeline_post_card.ex 75
check_max_lines apps/elektrine_social/lib/elektrine_social_web/components/social/timeline_post_compact.ex 175
check_max_lines apps/elektrine_social/lib/elektrine_social_web/components/social/timeline_post_footer.ex 250
check_max_lines apps/elektrine_social/lib/elektrine_social_web/components/social/timeline_post_media.ex 500
check_max_lines apps/elektrine_web/lib/elektrine_web/live/profile_live/edit.html.heex 2410
check_max_lines apps/elektrine_web/lib/elektrine_web/live/profile_live/effects_sections.ex 400
check_max_lines apps/elektrine_web/lib/elektrine_web/live/profile_live/edit_sections.ex 475
check_max_lines apps/elektrine_web/lib/elektrine_web/live/profile_live/design_sections.ex 500
check_max_lines apps/elektrine_web/lib/elektrine_web/live/profile_live/design_theme_sections.ex 325
check_max_lines apps/elektrine_email/lib/elektrine/imap/commands.ex 325
check_max_lines apps/elektrine_email/lib/elektrine/imap/commands/append.ex 325
check_max_lines apps/elektrine_email/lib/elektrine/imap/commands/auth.ex 400
check_max_lines apps/elektrine_email/lib/elektrine/imap/commands/idle.ex 150
check_max_lines apps/elektrine_email/lib/elektrine/imap/commands/mailbox.ex 475
check_max_lines apps/elektrine_email/lib/elektrine/imap/commands/message.ex 700
check_max_lines apps/elektrine_email/lib/elektrine/imap/commands/search.ex 200
check_max_lines apps/elektrine_email/lib/elektrine/imap/commands/shared.ex 50
check_max_lines apps/elektrine_email/lib/elektrine/imap/append_parser.ex 350
check_max_lines apps/elektrine_email/lib/elektrine/imap/folders.ex 225
check_max_lines apps/elektrine_email/lib/elektrine/imap/idle_tracker.ex 200
check_max_lines apps/elektrine_email/lib/elektrine/imap/recent_state.ex 100
check_max_lines apps/elektrine_email/lib/elektrine/pop3/connection_tracker.ex 170
check_max_lines apps/elektrine/test/elektrine/messaging/federation_test.exs 3885
check_max_lines apps/elektrine/test/elektrine/messaging/federation_dm_test.exs 450
check_max_lines apps/elektrine/test/elektrine/messaging/federation_room_participation_test.exs 225
check_max_lines apps/elektrine/test/elektrine/messaging/federation_peer_discovery_test.exs 600
check_max_lines apps/elektrine/test/elektrine/messaging/federation_peer_policy_test.exs 200
check_max_lines apps/elektrine/test/elektrine/messaging/federation_remote_join_test.exs 200
check_max_lines apps/elektrine/assets/js/hooks/backup_codes_printer.js 125
check_max_lines apps/elektrine/assets/js/hooks/chat_e2ee_crypto.js 350
check_max_lines apps/elektrine/assets/js/hooks/chat_e2ee_hook.js 1325
check_max_lines apps/elektrine/assets/js/hooks/chat_e2ee_messages.js 125
check_max_lines apps/elektrine/assets/js/hooks/chat_hooks.js 800
check_max_lines apps/elektrine/assets/js/hooks/chat_context_menu_hooks.js 200
check_max_lines apps/elektrine/assets/js/hooks/chat_voice_recorder_hook.js 200
check_max_lines apps/elektrine/assets/js/hooks/clipboard_hooks.js 150
check_max_lines apps/elektrine/assets/js/hooks/email_compose_shortcuts_hook.js 300
check_max_lines apps/elektrine/assets/js/hooks/email_hooks.js 825
check_max_lines apps/elektrine/assets/js/hooks/email_iframe_resize_hook.js 150
check_max_lines apps/elektrine/assets/js/hooks/email_shortcut_helpers.js 75
check_max_lines apps/elektrine/assets/js/hooks/file_explorer_hook.js 400
check_max_lines apps/elektrine/assets/js/hooks/mailbox_private_auth_forms.js 150
check_max_lines apps/elektrine/assets/js/hooks/mailbox_private_compose_hook.js 250
check_max_lines apps/elektrine/assets/js/hooks/mailbox_private_crypto.js 475
check_max_lines apps/elektrine/assets/js/hooks/mailbox_private_content.js 350
check_max_lines apps/elektrine/assets/js/hooks/mailbox_private_messages_hook.js 300
check_max_lines apps/elektrine/assets/js/hooks/mailbox_private_storage_hooks.js 700
check_max_lines apps/elektrine/assets/js/hooks/portal_dropdowns.js 325
check_max_lines apps/elektrine/assets/js/hooks/proof_graph_dom.js 50
check_max_lines apps/elektrine/assets/js/hooks/proof_graph_hook.js 675
check_max_lines apps/elektrine/assets/js/hooks/proof_graph_paints.js 275
check_max_lines apps/elektrine/assets/js/hooks/proof_graph_styles.js 150
check_max_lines apps/elektrine/assets/js/hooks/timeline_hooks.js 835
check_max_lines apps/elektrine/assets/js/hooks/timeline_media_hooks.js 175
check_max_lines apps/elektrine/assets/js/hooks/timeline_preservation_hooks.js 330
check_max_lines apps/elektrine/assets/js/hooks/timeline_session_continuity.js 150
check_max_lines apps/elektrine/assets/js/hooks/timeline_status_hooks.js 200
check_max_lines apps/elektrine/assets/js/hooks/ui_hooks.js 600
check_max_lines scripts/deploy/docker_deploy.sh 920
check_max_lines scripts/deploy/configure_haraka_wildcard_tls.sh 625
check_max_lines scripts/deploy/doctor.sh 585
check_max_lines scripts/deploy/self_host.sh 350
check_max_lines scripts/deploy/render_docker_compose.sh 200
check_max_lines scripts/deploy/generate_env.sh 250

if ((failures > 0)); then
  echo "Maintainability budgets failed with $failures issue(s)." >&2
  exit 1
fi

echo "Maintainability budgets passed."
