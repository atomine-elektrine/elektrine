defmodule Elektrine.Calls.Transport do
  @moduledoc false

  @default_turn_ttl_seconds 3600
  @default_resume_window_seconds 300

  def descriptor_for_user(user_id, call_id, opts \\ [])
      when is_integer(user_id) and is_integer(call_id) and is_list(opts) do
    config = Application.get_env(:elektrine, :webrtc, [])

    %{
      "mode" => transport_mode(config),
      "ice_servers" => ice_servers_for_user(user_id, call_id, opts),
      "resume_window_seconds" =>
        Keyword.get(config, :resume_window_seconds, @default_resume_window_seconds),
      "sfu" => maybe_sfu_descriptor(config, user_id, call_id)
    }
  end

  def ice_servers_for_user(user_id, call_id, opts \\ [])
      when is_integer(user_id) and is_integer(call_id) and is_list(opts) do
    config = Application.get_env(:elektrine, :webrtc, [])
    static_servers = normalize_ice_servers(Keyword.get(config, :ice_servers, []))
    dynamic_turn_servers = build_dynamic_turn_servers(config, user_id, call_id, opts)

    static_servers ++ dynamic_turn_servers
  end

  defp transport_mode(config) do
    case Keyword.get(config, :transport_mode, :mesh) do
      mode when mode in [:mesh, "mesh", :sfu, "sfu"] ->
        mode |> to_string()

      _ ->
        "mesh"
    end
  end

  defp maybe_sfu_descriptor(config, user_id, call_id) do
    endpoint = Keyword.get(config, :sfu_endpoint)
    token_secret = Keyword.get(config, :sfu_token_secret)

    cond do
      !is_binary(endpoint) or String.trim(endpoint) == "" ->
        nil

      !is_binary(token_secret) or String.trim(token_secret) == "" ->
        %{"endpoint" => endpoint}

      true ->
        claims = %{
          "user_id" => user_id,
          "call_id" => call_id,
          "exp" => System.system_time(:second) + @default_turn_ttl_seconds
        }

        %{
          "endpoint" => endpoint,
          "token" => Phoenix.Token.sign(ElektrineWeb.Endpoint, "webrtc_sfu", claims)
        }
    end
  end

  defp build_dynamic_turn_servers(config, user_id, call_id, opts) do
    secret = Keyword.get(config, :turn_shared_secret)
    uris = normalize_turn_uris(Keyword.get(config, :turn_uris, []))
    ttl_seconds = Keyword.get(config, :turn_username_ttl_seconds, @default_turn_ttl_seconds)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if is_binary(secret) and secret != "" and uris != [] do
      expires_at =
        now
        |> DateTime.add(ttl_seconds, :second)
        |> DateTime.to_unix()

      username = "#{expires_at}:#{user_id}:#{call_id}"
      credential = turn_credential(secret, username)

      [%{"urls" => uris, "username" => username, "credential" => credential}]
    else
      []
    end
  end

  defp turn_credential(secret, username) do
    :crypto.mac(:hmac, :sha, secret, username)
    |> Base.encode64()
  end

  defp normalize_ice_servers(servers) when is_list(servers) do
    Enum.map(servers, &normalize_ice_server/1)
  end

  defp normalize_ice_servers(_servers), do: []

  defp normalize_ice_server(%{} = server) do
    server
    |> Enum.into(%{}, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
    |> Map.update("urls", [], &normalize_turn_uris/1)
  end

  defp normalize_ice_server(_server), do: %{}

  defp normalize_turn_uris(uris) when is_list(uris) do
    uris
    |> Enum.map(fn
      uri when is_binary(uri) -> String.trim(uri)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_turn_uris(uri) when is_binary(uri), do: [String.trim(uri)]
  defp normalize_turn_uris(_uris), do: []
end
