defmodule ElektrineWeb.Components.Social.PostUtilities do
  @moduledoc """
  Compatibility wrapper for the social app post utility helpers.
  """

  def video_url?(url), do: ElektrineSocialWeb.Components.Social.PostUtilities.video_url?(url)

  def audio_url?(url), do: ElektrineSocialWeb.Components.Social.PostUtilities.audio_url?(url)

  def filter_image_urls(urls),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.filter_image_urls(urls)

  def extract_community_name(uri),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.extract_community_name(uri)

  def extract_community_name_simple(uri),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.extract_community_name_simple(uri)

  def detect_external_link(post),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.detect_external_link(post)

  def extract_url_from_content(content),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.extract_url_from_content(content)

  def render_content_preview(content),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.render_content_preview(content)

  def render_content_preview(content, instance_domain),
    do:
      ElektrineSocialWeb.Components.Social.PostUtilities.render_content_preview(
        content,
        instance_domain
      )

  def plain_text_content(content),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.plain_text_content(content)

  def plain_text_preview(content),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.plain_text_preview(content)

  def plain_text_preview(content, max_length),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.plain_text_preview(content, max_length)

  def get_instance_domain(item),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.get_instance_domain(item)

  def format_reactions(reactions, current_user_id),
    do:
      ElektrineSocialWeb.Components.Social.PostUtilities.format_reactions(
        reactions,
        current_user_id
      )

  def get_reply_author(reply),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.get_reply_author(reply)

  def get_reply_avatar_url(reply),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.get_reply_avatar_url(reply)

  def get_reply_content(reply),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.get_reply_content(reply)

  def get_reply_score(reply),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.get_reply_score(reply)

  def community_actor_uri(post),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.community_actor_uri(post)

  def has_community_uri?(post),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.has_community_uri?(post)

  def community_post?(post),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.community_post?(post)

  def reply?(post), do: ElektrineSocialWeb.Components.Social.PostUtilities.reply?(post)

  def gallery_post?(post),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.gallery_post?(post)

  def get_post_click_event(post),
    do: ElektrineSocialWeb.Components.Social.PostUtilities.get_post_click_event(post)

  def get_display_counts(post, lemmy_counts, post_replies),
    do:
      ElektrineSocialWeb.Components.Social.PostUtilities.get_display_counts(
        post,
        lemmy_counts,
        post_replies
      )
end
