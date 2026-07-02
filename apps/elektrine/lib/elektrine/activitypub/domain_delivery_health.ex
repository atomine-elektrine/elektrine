defmodule Elektrine.ActivityPub.DomainDeliveryHealth do
  @moduledoc """
  Uses instance reachability state to gate noisy remote delivery and fetch work.
  """

  alias Elektrine.ActivityPub.Instances

  def filter_deliverable_inboxes(inbox_urls) when is_list(inbox_urls) do
    inbox_urls = Enum.uniq(inbox_urls)
    deliverable = Enum.filter(inbox_urls, &deliverable_url?/1)
    paused = length(inbox_urls) - length(deliverable)

    if paused > 0 do
      :telemetry.execute(
        [:elektrine, :federation, :domain_delivery, :paused],
        %{count: paused},
        %{}
      )
    end

    deliverable
  end

  def deliverable_url?(url) when is_binary(url) do
    case domain_for_url(url) do
      domain when is_binary(domain) -> Instances.should_retry?(domain)
      _ -> false
    end
  end

  def deliverable_url?(_url), do: false

  def record_delivery_success(url) when is_binary(url) do
    with domain when is_binary(domain) <- domain_for_url(url) do
      _ = Instances.set_reachable(domain)
    end

    :ok
  rescue
    _ -> :ok
  end

  def record_delivery_success(_url), do: :ok

  def record_delivery_failure(url, _reason) when is_binary(url) do
    with domain when is_binary(domain) <- domain_for_url(url) do
      _ = Instances.set_unreachable(domain)
    end

    :ok
  rescue
    _ -> :ok
  end

  def record_delivery_failure(_url, _reason), do: :ok

  def domain_for_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        host |> String.trim() |> String.downcase()

      _ ->
        nil
    end
  end

  def domain_for_url(_url), do: nil
end
