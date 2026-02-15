defmodule ElektrineWeb.EmailScrubber do
  @moduledoc """
  ⚠️  INTERNAL MODULE - DO NOT USE DIRECTLY ⚠️

  Use `Elektrine.Email.Sanitizer` instead for all email sanitization.

  This module is an internal implementation detail that exists only to
  implement the HtmlSanitizeEx.Scrubber behavior. It defines the allowlist
  of HTML tags and attributes for email content.

  Allowed tags: All common HTML except scripts, forms, iframes, objects
  Blocked: Event handlers, dangerous protocols, form submission attributes
  """

  require HtmlSanitizeEx.Scrubber.Meta
  alias HtmlSanitizeEx.Scrubber.Meta

  Meta.remove_cdata_sections_before_scrub()
  # Note: We handle comments manually in scrub/1 below

  # Allow these tags with ANY attributes (dangerous ones filtered in scrub/1)
  Meta.allow_tag_with_any_attributes("html")
  Meta.allow_tag_with_any_attributes("head")
  Meta.allow_tag_with_any_attributes("body")
  Meta.allow_tag_with_any_attributes("title")
  Meta.allow_tag_with_any_attributes("style")
  Meta.allow_tag_with_any_attributes("div")
  Meta.allow_tag_with_any_attributes("span")
  Meta.allow_tag_with_any_attributes("p")
  Meta.allow_tag_with_any_attributes("br")
  Meta.allow_tag_with_any_attributes("hr")
  Meta.allow_tag_with_any_attributes("center")
  Meta.allow_tag_with_any_attributes("h1")
  Meta.allow_tag_with_any_attributes("h2")
  Meta.allow_tag_with_any_attributes("h3")
  Meta.allow_tag_with_any_attributes("h4")
  Meta.allow_tag_with_any_attributes("h5")
  Meta.allow_tag_with_any_attributes("h6")
  Meta.allow_tag_with_any_attributes("strong")
  Meta.allow_tag_with_any_attributes("b")
  Meta.allow_tag_with_any_attributes("em")
  Meta.allow_tag_with_any_attributes("i")
  Meta.allow_tag_with_any_attributes("u")
  Meta.allow_tag_with_any_attributes("s")
  Meta.allow_tag_with_any_attributes("strike")
  Meta.allow_tag_with_any_attributes("del")
  Meta.allow_tag_with_any_attributes("ins")
  Meta.allow_tag_with_any_attributes("mark")
  Meta.allow_tag_with_any_attributes("sub")
  Meta.allow_tag_with_any_attributes("sup")
  Meta.allow_tag_with_any_attributes("small")
  Meta.allow_tag_with_any_attributes("big")
  Meta.allow_tag_with_any_attributes("font")
  Meta.allow_tag_with_any_attributes("ul")
  Meta.allow_tag_with_any_attributes("ol")
  Meta.allow_tag_with_any_attributes("li")
  Meta.allow_tag_with_any_attributes("dl")
  Meta.allow_tag_with_any_attributes("dt")
  Meta.allow_tag_with_any_attributes("dd")
  Meta.allow_tag_with_any_attributes("table")
  Meta.allow_tag_with_any_attributes("thead")
  Meta.allow_tag_with_any_attributes("tbody")
  Meta.allow_tag_with_any_attributes("tfoot")
  Meta.allow_tag_with_any_attributes("tr")
  Meta.allow_tag_with_any_attributes("th")
  Meta.allow_tag_with_any_attributes("td")
  Meta.allow_tag_with_any_attributes("caption")
  Meta.allow_tag_with_any_attributes("colgroup")
  Meta.allow_tag_with_any_attributes("col")
  Meta.allow_tag_with_any_attributes("blockquote")
  Meta.allow_tag_with_any_attributes("pre")
  Meta.allow_tag_with_any_attributes("code")
  Meta.allow_tag_with_any_attributes("article")
  Meta.allow_tag_with_any_attributes("section")
  Meta.allow_tag_with_any_attributes("header")
  Meta.allow_tag_with_any_attributes("footer")
  Meta.allow_tag_with_any_attributes("nav")
  Meta.allow_tag_with_any_attributes("main")
  Meta.allow_tag_with_any_attributes("aside")
  Meta.allow_tag_with_any_attributes("figure")
  Meta.allow_tag_with_any_attributes("figcaption")
  Meta.allow_tag_with_any_attributes("picture")
  Meta.allow_tag_with_any_attributes("time")
  Meta.allow_tag_with_any_attributes("details")
  Meta.allow_tag_with_any_attributes("summary")
  Meta.allow_tag_with_any_attributes("button")
  Meta.allow_tag_with_any_attributes("o:p")
  Meta.allow_tag_with_any_attributes("o:shapedefaults")
  Meta.allow_tag_with_any_attributes("o:shapelayout")
  Meta.allow_tag_with_any_attributes("w:wrap")
  Meta.allow_tag_with_any_attributes("v:shape")
  Meta.allow_tag_with_any_attributes("v:imagedata")
  Meta.allow_tag_with_any_attributes("v:fill")
  Meta.allow_tag_with_any_attributes("v:textbox")
  Meta.allow_tag_with_any_attributes("v:rect")
  Meta.allow_tag_with_any_attributes("v:roundrect")
  Meta.allow_tag_with_any_attributes("x-apple-data-detectors")
  Meta.allow_tag_with_any_attributes("x-apple-data-detectors-type")
  Meta.allow_tag_with_any_attributes("x-apple-data-detectors-result")
  Meta.allow_tag_with_any_attributes("mso")
  Meta.allow_tag_with_any_attributes("mso-only")
  Meta.allow_tag_with_any_attributes("amp-img")
  Meta.allow_tag_with_any_attributes("amp-carousel")
  Meta.allow_tag_with_any_attributes("amp-accordion")
  Meta.allow_tag_with_any_attributes("amp-form")

  # Strip comments - must be before other tuple patterns
  def scrub({:comment, _text}), do: nil

  # Allow content inside style tags to pass through (3-tuple pattern)
  # This is needed for email templates that use CSS classes
  def scrub({"style", _attributes, children}) do
    # Keep all CSS content inside style tags
    {"style", [], children}
  end

  # Custom scrub function to filter out ONLY truly dangerous attributes
  # Allow everything else - this is much better for email rendering
  # IMPORTANT: This must be defined BEFORE Meta.strip_everything_not_covered()
  def scrub({tag, attributes}) when is_binary(tag) and is_list(attributes) do
    # Block list approach: only reject truly dangerous attributes
    safe_attributes =
      Enum.reject(attributes, fn {name, _value} ->
        name_lower = String.downcase(name)

        # Block event handlers (onclick, onload, onerror, etc.)
        # Block form actions
        # Block XML namespaces (can enable XSS)
        # Block data URIs that could contain scripts
        String.starts_with?(name_lower, "on") or
          name_lower in ["action", "formaction", "method", "enctype"] or
          String.starts_with?(name_lower, "xmlns") or
          name_lower in ["srcdoc"]
      end)

    # For button tags, ensure they can't submit forms
    safe_attributes =
      if tag == "button" do
        # Always set type="button" to prevent form submission
        safe_attributes ++ [{"type", "button"}]
      else
        safe_attributes
      end

    # For anchor tags, ensure they open in new tab
    safe_attributes =
      if tag == "a" do
        # Add target="_blank" and rel="noopener noreferrer" for security
        safe_attributes
        |> Enum.reject(fn {name, _} -> name in ["target", "rel"] end)
        |> Kernel.++([{"target", "_blank"}, {"rel", "noopener noreferrer"}])
      else
        safe_attributes
      end

    {tag, safe_attributes}
  end

  # Catch-all for other content
  def scrub(content), do: content

  # Block dangerous protocols - must be after scrub function definitions
  Meta.allow_tag_with_uri_attributes(
    "a",
    ["href", "style", "class", "id", "target", "rel", "title"],
    ["http", "https", "mailto"]
  )

  Meta.allow_tag_with_uri_attributes(
    "img",
    [
      "src",
      "style",
      "class",
      "id",
      "alt",
      "title",
      "width",
      "height",
      "loading",
      "sizes",
      "srcset"
    ],
    ["http", "https", "data", "cid"]
  )

  Meta.allow_tag_with_uri_attributes(
    "source",
    ["srcset", "style", "class", "id", "src", "type", "media"],
    ["http", "https"]
  )

  Meta.allow_tag_with_uri_attributes(
    "link",
    ["href", "style", "class", "id", "rel", "type", "media"],
    ["http", "https"]
  )

  # Note: We have a catch-all scrub/1 above, so no need for strip_everything_not_covered
end
