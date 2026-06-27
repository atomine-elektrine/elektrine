defmodule ElektrineSocialWeb.ActivityPub.SignatureActorVerifier do
  @moduledoc false

  alias Elektrine.ActivityPub

  def verified_actor_domain(conn) do
    case conn.assigns[:signature_actor] do
      %{uri: uri} when is_binary(uri) -> actor_domain(uri)
      %Elektrine.Accounts.User{} -> ActivityPub.instance_url() |> actor_domain()
      _ -> nil
    end
  end

  def validate(conn, actor_uri) do
    case conn.assigns[:signature_actor] do
      %{uri: sig_actor_uri} = sig_actor ->
        if signature_actor_matches?(sig_actor_uri, actor_uri, sig_actor) do
          :ok
        else
          {:error,
           {:signature_actor_mismatch,
            %{
              actor: actor_uri,
              signature_actor: sig_actor_uri,
              signature_actor_username: Map.get(sig_actor, :username),
              key_id: signing_key_id(conn.assigns[:signing_key])
            }}}
        end

      %Elektrine.Accounts.User{} = user ->
        case ActivityPub.local_username_from_uri(actor_uri) do
          {:ok, username} when username == user.username -> :ok
          _ -> {:error, "signature actor mismatch"}
        end

      _ ->
        case conn.assigns[:signing_key] do
          %Elektrine.ActivityPub.SigningKey{key_id: key_id} ->
            if comparable_uri(signing_key_actor_uri(key_id)) == comparable_uri(actor_uri) do
              :ok
            else
              {:error,
               {:signature_actor_mismatch,
                %{
                  actor: actor_uri,
                  signature_actor: signing_key_actor_uri(key_id),
                  key_id: key_id
                }}}
            end

          _ ->
            {:error, "signature actor unavailable"}
        end
    end
  end

  defp actor_domain(actor_uri) when is_binary(actor_uri) do
    case URI.parse(actor_uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> "unknown"
    end
  end

  defp actor_domain(_), do: "unknown"

  defp signing_key_actor_uri(key_id) when is_binary(key_id) do
    key_id
    |> String.split("#", parts: 2)
    |> List.first()
  end

  defp signing_key_actor_uri(_), do: nil

  defp signing_key_id(%Elektrine.ActivityPub.SigningKey{key_id: key_id}), do: key_id
  defp signing_key_id(_), do: nil

  defp comparable_uri(uri) when is_binary(uri) do
    uri
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        case URI.parse(trimmed) do
          %URI{scheme: scheme, host: host} = parsed
          when is_binary(scheme) and is_binary(host) and host != "" ->
            normalized_path =
              parsed.path
              |> Kernel.||("/")
              |> normalize_activitypub_actor_path()
              |> case do
                "/" -> "/"
                path -> String.trim_trailing(path, "/")
              end

            parsed
            |> Map.put(:scheme, String.downcase(scheme))
            |> Map.put(:host, String.downcase(host))
            |> Map.put(:path, normalized_path)
            |> Map.put(:fragment, nil)
            |> URI.to_string()

          _ ->
            trimmed
        end
    end
  end

  defp comparable_uri(_), do: nil

  defp signature_actor_matches?(sig_actor_uri, actor_uri, sig_actor) do
    comparable_uri(sig_actor_uri) == comparable_uri(actor_uri) ||
      signature_actor_username_alias_match?(sig_actor_uri, actor_uri, sig_actor) ||
      signature_actor_reciprocal_alias_match?(sig_actor_uri, actor_uri, sig_actor)
  end

  defp signature_actor_username_alias_match?(sig_actor_uri, actor_uri, sig_actor)
       when is_binary(sig_actor_uri) and is_binary(actor_uri) do
    with %URI{host: sig_host} <- URI.parse(sig_actor_uri),
         %URI{host: actor_host} <- URI.parse(actor_uri),
         true <- is_binary(sig_host) and is_binary(actor_host),
         true <- String.downcase(sig_host) == String.downcase(actor_host),
         username when is_binary(username) and username != "" <- Map.get(sig_actor, :username),
         actor_username when is_binary(actor_username) and actor_username != "" <-
           Elektrine.ActivityPub.Helpers.extract_username_from_uri(actor_uri) do
      String.downcase(username) == String.downcase(actor_username)
    else
      _ -> false
    end
  end

  defp signature_actor_username_alias_match?(_, _, _), do: false

  defp signature_actor_reciprocal_alias_match?(sig_actor_uri, actor_uri, sig_actor)
       when is_binary(sig_actor_uri) and is_binary(actor_uri) and is_map(sig_actor) do
    normalized_actor_uri = comparable_uri(actor_uri)
    normalized_sig_actor_uri = comparable_uri(sig_actor_uri)

    sig_alias_uris = actor_alias_uris(sig_actor) |> Enum.map(&comparable_uri/1)

    if normalized_actor_uri in sig_alias_uris do
      case ActivityPub.get_or_fetch_actor(actor_uri) do
        {:ok, claimed_actor} ->
          claimed_alias_uris = actor_alias_uris(claimed_actor) |> Enum.map(&comparable_uri/1)
          normalized_sig_actor_uri in claimed_alias_uris

        _ ->
          false
      end
    else
      false
    end
  end

  defp signature_actor_reciprocal_alias_match?(_, _, _), do: false

  defp actor_alias_uris(%{metadata: metadata}) do
    extract_uri_candidates(metadata, "movedTo") ++ extract_uri_candidates(metadata, "alsoKnownAs")
  end

  defp actor_alias_uris(_), do: []

  defp extract_uri_candidates(metadata, field) when is_map(metadata) do
    metadata
    |> Map.get(field)
    |> expand_uri_candidates()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_uri_candidates(_metadata, _field), do: []

  defp expand_uri_candidates(value) when is_binary(value), do: [value]

  defp expand_uri_candidates(values) when is_list(values),
    do: Enum.flat_map(values, &expand_uri_candidates/1)

  defp expand_uri_candidates(%{"id" => id}) when is_binary(id), do: [id]
  defp expand_uri_candidates(%{"href" => href}) when is_binary(href), do: [href]
  defp expand_uri_candidates(%{"url" => url}) when is_binary(url), do: [url]
  defp expand_uri_candidates(_), do: []

  defp normalize_activitypub_actor_path(path) when is_binary(path) do
    case Regex.run(~r|^/@([^/?#]+)$|, path) do
      [_, username] -> "/users/#{username}"
      _ -> path
    end
  end

  defp normalize_activitypub_actor_path(_), do: "/"
end
