defmodule ElektrineEmailWeb.Admin.CustomDomainsHTML do
  @moduledoc """
  View helpers and templates for admin custom domain inspection.
  """

  use ElektrineEmailWeb, :html

  embed_templates "custom_domains_html/*"

  def build_custom_domains_url(search, status, page) do
    params = []

    params =
      if Elektrine.Strings.present?(search) do
        params ++ ["search=#{URI.encode_www_form(search)}"]
      else
        params
      end

    params = if status != "all", do: params ++ ["status=#{status}"], else: params
    params = params ++ ["page=#{page}"]

    "/pripyat/custom-domains?" <> Enum.join(params, "&")
  end

  def custom_domain_filter_label("all"), do: "All Domains"
  def custom_domain_filter_label("verified"), do: "Verified"
  def custom_domain_filter_label("pending"), do: "Pending"
  def custom_domain_filter_label("attention"), do: "Needs Attention"
  def custom_domain_filter_label(_), do: "Custom Domains"

  def custom_domain_status_badge_class("verified"), do: "bg-success/15 text-success"
  def custom_domain_status_badge_class("pending"), do: "bg-secondary/15 text-secondary"
  def custom_domain_status_badge_class(_), do: "bg-base-200 text-base-content/70"

  def custom_domain_health(custom_domain) do
    cond do
      present_error?(custom_domain.dkim_last_error) -> :attention
      present_error?(custom_domain.last_error) -> :attention
      custom_domain.status == "verified" -> :healthy
      true -> :pending
    end
  end

  def custom_domain_health_badge_class(:healthy), do: "bg-success/15 text-success"
  def custom_domain_health_badge_class(:pending), do: "bg-info/15 text-info"
  def custom_domain_health_badge_class(:attention), do: "bg-warning/20 text-warning-content"
  def custom_domain_health_badge_class(_), do: "bg-base-200 text-base-content/70"

  def custom_domain_health_label(:healthy), do: "Healthy"
  def custom_domain_health_label(:pending), do: "Pending DNS"
  def custom_domain_health_label(:attention), do: "Needs Attention"
  def custom_domain_health_label(_), do: "Unknown"

  def custom_domain_primary_email(%{user: %{username: username}, domain: domain})
      when is_binary(username) and is_binary(domain) do
    "#{username}@#{domain}"
  end

  def custom_domain_primary_email(%{domain: domain}) when is_binary(domain), do: "@#{domain}"
  def custom_domain_primary_email(_), do: "Unavailable"

  def custom_domain_error_summary(custom_domain) do
    [custom_domain.last_error, custom_domain.dkim_last_error]
    |> Enum.filter(&present_error?/1)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      message -> message
    end
  end

  def custom_domain_dkim_state_label(custom_domain) do
    cond do
      present_error?(custom_domain.dkim_last_error) -> "Sync issue"
      custom_domain.dkim_synced_at -> "Synced"
      true -> "Waiting for sync"
    end
  end

  def custom_domain_dkim_state_class(custom_domain) do
    cond do
      present_error?(custom_domain.dkim_last_error) -> "text-warning"
      custom_domain.dkim_synced_at -> "text-success"
      true -> "text-base-content/55"
    end
  end

  defp present_error?(value) when is_binary(value), do: Elektrine.Strings.present?(value)
  defp present_error?(_), do: false
end
