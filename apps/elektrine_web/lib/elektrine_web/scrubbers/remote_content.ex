defmodule ElektrineWeb.Scrubbers.RemoteContent do
  @moduledoc """
  Custom HTML scrubber for remote/federated content.
  Allows basic HTML plus img tags for embedded images.
  """

  require HtmlSanitizeEx.Scrubber.Meta
  alias HtmlSanitizeEx.Scrubber.Meta

  # Allow basic formatting tags
  Meta.remove_cdata_sections_before_scrub()
  Meta.strip_comments()

  # Allow text formatting
  Meta.allow_tag_with_these_attributes("b", [])
  Meta.allow_tag_with_these_attributes("i", [])
  Meta.allow_tag_with_these_attributes("u", [])
  Meta.allow_tag_with_these_attributes("s", [])
  Meta.allow_tag_with_these_attributes("em", [])
  Meta.allow_tag_with_these_attributes("strong", [])
  Meta.allow_tag_with_these_attributes("strike", [])
  Meta.allow_tag_with_these_attributes("del", [])
  Meta.allow_tag_with_these_attributes("sub", [])
  Meta.allow_tag_with_these_attributes("sup", [])
  Meta.allow_tag_with_these_attributes("code", [])
  Meta.allow_tag_with_these_attributes("pre", [])
  Meta.allow_tag_with_these_attributes("blockquote", [])

  # Allow structure tags
  Meta.allow_tag_with_these_attributes("p", [])
  Meta.allow_tag_with_these_attributes("br", [])
  Meta.allow_tag_with_these_attributes("hr", [])
  Meta.allow_tag_with_these_attributes("span", ["class"])
  Meta.allow_tag_with_these_attributes("div", ["class"])

  # Allow lists
  Meta.allow_tag_with_these_attributes("ul", [])
  Meta.allow_tag_with_these_attributes("ol", [])
  Meta.allow_tag_with_these_attributes("li", [])

  # Allow links with safe attributes
  Meta.allow_tag_with_uri_attributes("a", ["href"], ["http", "https", "mailto"])
  Meta.allow_tag_with_these_attributes("a", ["class", "rel", "target", "title"])

  # Allow images with safe attributes (for embedded markdown images)
  Meta.allow_tag_with_uri_attributes("img", ["src"], ["http", "https"])

  Meta.allow_tag_with_these_attributes("img", [
    "alt",
    "class",
    "loading",
    "title",
    "width",
    "height"
  ])

  # Strip everything else
  Meta.strip_everything_not_covered()
end
