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
check_max_lines config/runtime.exs 1650
check_max_lines apps/elektrine/priv/repo/seeds.exs 2700
check_max_lines_matching "apps/*/priv/repo/migrations/*.exs" 350
check_max_lines apps/elektrine/lib/elektrine/activitypub.ex 2500
check_max_lines apps/elektrine/lib/elektrine/activitypub/normalizer.ex 1400
check_max_lines apps/elektrine_social/lib/elektrine_social_web/controllers/activitypub_controller.ex 1500
check_max_lines_matching "apps/elektrine/lib/elektrine/messaging/federation/*.ex" 1650
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/show.ex 6400
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/detail_state.ex 400
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/detail_components.ex 200
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/ancestor_context_components.ex 300
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/threaded_comment_components.ex 1050
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/quick_reply_components.ex 400
check_max_lines apps/elektrine_social/lib/elektrine_social_web/live/remote_post_live/reply_author_components.ex 300
check_max_lines apps/elektrine_web/lib/elektrine_web/live/portal_live/index.ex 3600
check_max_lines apps/elektrine_web/lib/elektrine_web/live/portal_live/activity_inspector.ex 450
check_max_lines apps/elektrine_web/lib/elektrine_web/live/portal_live/dashboard_data.ex 150
check_max_lines apps/elektrine_social/lib/elektrine_social_web/components/social/timeline_post.ex 3100
check_max_lines apps/elektrine_social/lib/elektrine_social_web/components/social/timeline_post_footer.ex 250
check_max_lines apps/elektrine_social/lib/elektrine_social_web/components/social/timeline_post_media.ex 500
check_max_lines apps/elektrine_web/lib/elektrine_web/live/profile_live/edit.html.heex 2950
check_max_lines apps/elektrine_web/lib/elektrine_web/live/profile_live/edit_sections.ex 350
check_max_lines apps/elektrine_web/lib/elektrine_web/live/profile_live/design_sections.ex 360
check_max_lines apps/elektrine_email/lib/elektrine/imap/commands.ex 2700
check_max_lines apps/elektrine_email/lib/elektrine/imap/append_parser.ex 350
check_max_lines apps/elektrine_email/lib/elektrine/imap/idle_tracker.ex 200
check_max_lines apps/elektrine_email/lib/elektrine/pop3/connection_tracker.ex 170
check_max_lines apps/elektrine/test/elektrine/messaging/federation_test.exs 4350
check_max_lines apps/elektrine/test/elektrine/messaging/federation_peer_discovery_test.exs 600
check_max_lines apps/elektrine/test/elektrine/messaging/federation_peer_policy_test.exs 200
check_max_lines apps/elektrine/test/elektrine/messaging/federation_remote_join_test.exs 200
check_max_lines apps/elektrine/assets/js/hooks/chat_hooks.js 2425
check_max_lines apps/elektrine/assets/js/hooks/chat_context_menu_hooks.js 200
check_max_lines apps/elektrine/assets/js/hooks/chat_voice_recorder_hook.js 200
check_max_lines apps/elektrine/assets/js/hooks/mailbox_private_storage_hooks.js 1500
check_max_lines apps/elektrine/assets/js/hooks/timeline_hooks.js 1500
check_max_lines scripts/deploy/docker_deploy.sh 875
check_max_lines scripts/deploy/configure_haraka_wildcard_tls.sh 625
check_max_lines scripts/deploy/doctor.sh 525
check_max_lines scripts/deploy/self_host.sh 350
check_max_lines scripts/deploy/render_docker_compose.sh 200
check_max_lines scripts/deploy/generate_env.sh 200

if ((failures > 0)); then
  echo "Maintainability budgets failed with $failures issue(s)." >&2
  exit 1
fi

echo "Maintainability budgets passed."
