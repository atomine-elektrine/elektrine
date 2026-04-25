defmodule Elektrine.ActorPaths do
  @moduledoc false

  defdelegate post_path(ref), to: Elektrine.Paths
  defdelegate remote_post_path(ref), to: Elektrine.Paths
  defdelegate local_post_path(ref), to: Elektrine.Paths
  defdelegate post_anchor(message_id), to: Elektrine.Paths
  defdelegate anchored_post_path(post_ref, anchor_message_id), to: Elektrine.Paths
  defdelegate chat_path(ref), to: Elektrine.Paths
  defdelegate chat_message_path(conversation_ref, message_id), to: Elektrine.Paths
  defdelegate chat_root_message_path(message_id), to: Elektrine.Paths
  defdelegate discussion_path(community_name), to: Elektrine.Paths
  defdelegate discussion_post_path(community_name, post_id), to: Elektrine.Paths
  defdelegate discussion_post_path(community_name, post_id, title), to: Elektrine.Paths
  defdelegate discussion_message_path(community_name, post_id, message_id), to: Elektrine.Paths
  defdelegate email_view_path(ref), to: Elektrine.Paths
  defdelegate notifications_path(), to: Elektrine.Paths
  defdelegate portal_path(), to: Elektrine.Paths
  defdelegate search_path(), to: Elektrine.Paths
  defdelegate login_path(), to: Elektrine.Paths
  defdelegate register_path(), to: Elektrine.Paths
  defdelegate timeline_path(), to: Elektrine.Paths
  defdelegate timeline_path(params), to: Elektrine.Paths
  defdelegate chat_root_path(), to: Elektrine.Paths
  defdelegate chat_root_path(params), to: Elektrine.Paths
  defdelegate chat_join_path(ref), to: Elektrine.Paths
  defdelegate email_index_path(), to: Elektrine.Paths
  defdelegate email_index_path(params), to: Elektrine.Paths
  defdelegate email_compose_path(params), to: Elektrine.Paths
  defdelegate email_settings_path(), to: Elektrine.Paths
  defdelegate friends_path(), to: Elektrine.Paths
  defdelegate friends_path(params), to: Elektrine.Paths
  defdelegate lists_path(), to: Elektrine.Paths
  defdelegate lists_path(fragment), to: Elektrine.Paths
  defdelegate calendar_path(), to: Elektrine.Paths
  defdelegate calendar_path(params), to: Elektrine.Paths
  defdelegate discussions_path(), to: Elektrine.Paths
  defdelegate vpn_path(), to: Elektrine.Paths
  defdelegate vpn_policy_path(), to: Elektrine.Paths
  defdelegate hashtag_path(hashtag), to: Elektrine.Paths
  defdelegate community_path(name), to: Elektrine.Paths
  defdelegate admin_path(), to: Elektrine.Paths
  defdelegate admin_path(section), to: Elektrine.Paths
  defdelegate admin_user_edit_path(user_id), to: Elektrine.Paths
  defdelegate admin_chat_message_path(message_id), to: Elektrine.Paths
  defdelegate profile_path(handle), to: Elektrine.Paths
  defdelegate profile_path(username, domain), to: Elektrine.Paths
  defdelegate local_profile_path(handle), to: Elektrine.Paths
  defdelegate local_profile_path(username, domain), to: Elektrine.Paths
  defdelegate remote_profile_path(username, domain), to: Elektrine.Paths
end
