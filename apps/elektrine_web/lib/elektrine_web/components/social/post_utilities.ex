defmodule ElektrineWeb.Components.Social.PostUtilities do
  @moduledoc """
  Compatibility wrapper for the social app post utility helpers.
  """

  alias ElektrineWeb.HtmlHelpers
  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.PostUtilities"

  def video_url?(url),
    do: OptionalModule.call(:social, @component_module, :video_url?, [url], false)

  def audio_url?(url),
    do: OptionalModule.call(:social, @component_module, :audio_url?, [url], false)

  def filter_image_urls(urls),
    do: OptionalModule.call(:social, @component_module, :filter_image_urls, [urls], [])

  def extract_community_name(uri),
    do: OptionalModule.call(:social, @component_module, :extract_community_name, [uri], "")

  def extract_community_name_simple(uri),
    do:
      OptionalModule.call(
        :social,
        @component_module,
        :extract_community_name_simple,
        [uri],
        "Community"
      )

  def detect_external_link(post),
    do: OptionalModule.call(:social, @component_module, :detect_external_link, [post], nil)

  def extract_url_from_content(content),
    do: OptionalModule.call(:social, @component_module, :extract_url_from_content, [content], nil)

  def render_content_preview(content),
    do:
      OptionalModule.call(
        :social,
        @component_module,
        :render_content_preview,
        [content],
        HtmlHelpers.plain_text_preview(content, 200)
      )

  def render_content_preview(content, instance_domain),
    do:
      OptionalModule.call(
        :social,
        @component_module,
        :render_content_preview,
        [content, instance_domain],
        HtmlHelpers.plain_text_preview(content, 200)
      )

  def plain_text_content(content),
    do:
      OptionalModule.call(
        :social,
        @component_module,
        :plain_text_content,
        [content],
        HtmlHelpers.plain_text_content(content)
      )

  def plain_text_preview(content),
    do:
      OptionalModule.call(
        :social,
        @component_module,
        :plain_text_preview,
        [content],
        HtmlHelpers.plain_text_preview(content)
      )

  def plain_text_preview(content, max_length),
    do:
      OptionalModule.call(
        :social,
        @component_module,
        :plain_text_preview,
        [content, max_length],
        HtmlHelpers.plain_text_preview(content, max_length)
      )

  def get_instance_domain(item),
    do: OptionalModule.call(:social, @component_module, :get_instance_domain, [item], nil)

  def format_reactions(reactions, current_user_id),
    do:
      OptionalModule.call(
        :social,
        @component_module,
        :format_reactions,
        [reactions, current_user_id],
        []
      )

  def get_reply_author(reply),
    do: OptionalModule.call(:social, @component_module, :get_reply_author, [reply], nil)

  def get_reply_avatar_url(reply),
    do: OptionalModule.call(:social, @component_module, :get_reply_avatar_url, [reply], nil)

  def get_reply_content(reply),
    do: OptionalModule.call(:social, @component_module, :get_reply_content, [reply], nil)

  def get_reply_score(reply),
    do: OptionalModule.call(:social, @component_module, :get_reply_score, [reply], 0)

  def community_actor_uri(post),
    do: OptionalModule.call(:social, @component_module, :community_actor_uri, [post], nil)

  def has_community_uri?(post),
    do: OptionalModule.call(:social, @component_module, :has_community_uri?, [post], false)

  def community_post?(post),
    do: OptionalModule.call(:social, @component_module, :community_post?, [post], false)

  def reply?(post), do: OptionalModule.call(:social, @component_module, :reply?, [post], false)

  def gallery_post?(post),
    do: OptionalModule.call(:social, @component_module, :gallery_post?, [post], false)

  def get_display_counts(post, lemmy_counts, post_replies),
    do:
      OptionalModule.call(
        :social,
        @component_module,
        :get_display_counts,
        [post, lemmy_counts, post_replies],
        %{}
      )
end
