defmodule Elektrine.ActivityPub.MRF.UserAllowListPolicy do
  @moduledoc """
  Restricts selected remote domains to configured actor allowlists.
  """

  @behaviour Elektrine.ActivityPub.MRF.Policy

  @impl true
  def filter(%{"actor" => actor} = activity) when is_binary(actor) do
    with host when is_binary(host) <- actor_host(actor),
         allow_list when is_list(allow_list) and allow_list != [] <- allow_list_for_host(host) do
      if actor in allow_list do
        {:ok, activity}
      else
        {:reject, "[UserAllowListPolicy] #{actor} not in allowlist for #{host}"}
      end
    else
      _ -> {:ok, activity}
    end
  end

  def filter(activity), do: {:ok, activity}

  @impl true
  def describe do
    hosts =
      :elektrine
      |> Application.get_env(:mrf_user_allowlist, [])
      |> Keyword.get(:hosts, %{})
      |> Map.new(fn {host, actors} -> {host, length(List.wrap(actors))} end)

    {:ok, %{mrf_user_allowlist: hosts}}
  end

  defp allow_list_for_host(host) do
    config = Application.get_env(:elektrine, :mrf_user_allowlist, [])

    config
    |> Keyword.get(:hosts, %{})
    |> get_host_value(host)
  end

  defp get_host_value(map, host) when is_map(map) do
    Map.get(map, host) || Map.get(map, String.to_atom(host))
  rescue
    ArgumentError -> Map.get(map, host)
  end

  defp get_host_value(keyword, host) when is_list(keyword),
    do: Keyword.get(keyword, String.to_atom(host), [])

  defp get_host_value(_config, _host), do: []

  defp actor_host(actor) do
    case URI.parse(actor) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  end
end
