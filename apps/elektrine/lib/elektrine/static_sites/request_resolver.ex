defmodule Elektrine.StaticSites.RequestResolver do
  @moduledoc """
  Resolves profile static-site request paths into uploaded files.

  Static-profile hosts behave like a dedicated web root: uploaded files are served
  with normal static-site fallbacks, while only platform runtime endpoints are
  reserved for the application.
  """

  alias Elektrine.StaticSites

  @type host_mode :: :subdomain | :custom_domain
  @type result :: {:ok, struct()} | :reserved | :not_found

  @doc """
  Resolves a request path for a static site.

  Lookup order is:

    * exact file path
    * directory `index.html` for paths ending in `/`
    * extensionless `.html`
    * extensionless `/index.html`
  """
  @spec resolve(pos_integer(), binary(), keyword()) :: result()
  def resolve(user_id, request_path, opts \\ [])

  def resolve(user_id, request_path, opts) when is_integer(user_id) and is_binary(request_path) do
    mode = Keyword.get(opts, :mode, :subdomain)

    with {:ok, site_path} <- normalize_request_path(request_path),
         false <- platform_path?(site_path, mode) do
      site_path
      |> lookup_candidates()
      |> Enum.find_value(:not_found, fn path ->
        case StaticSites.get_file(user_id, path) do
          nil -> nil
          file -> {:ok, file}
        end
      end)
    else
      true -> :reserved
      :error -> :not_found
    end
  end

  def resolve(_, _, _), do: :not_found

  @doc """
  Returns true when a normalized static-site path is reserved for the platform.
  """
  @spec platform_path?(binary(), host_mode()) :: boolean()
  def platform_path?("", _mode), do: false

  def platform_path?(path, :custom_domain) when is_binary(path) do
    critical_platform_path?(path)
  end

  def platform_path?(path, :subdomain) when is_binary(path) do
    critical_platform_path?(path) or String.starts_with?(path, ".well-known/")
  end

  def platform_path?(path, _mode) when is_binary(path), do: platform_path?(path, :subdomain)

  @doc """
  Builds file lookup candidates for a normalized static-site path.
  """
  @spec lookup_candidates(binary()) :: [binary()]
  def lookup_candidates("") do
    ["index.html"]
  end

  def lookup_candidates(path) when is_binary(path) do
    cond do
      String.ends_with?(path, "/") ->
        [path <> "index.html"]

      Path.extname(path) != "" ->
        [path]

      true ->
        [path, path <> ".html", path <> "/index.html"]
    end
  end

  defp normalize_request_path(request_path) do
    decoded_path = URI.decode(request_path) |> String.trim()
    site_path = String.trim_leading(decoded_path, "/")
    normalized = Path.expand(site_path, "/")

    cond do
      String.contains?(decoded_path, ["..", "\0", "//", "\\"]) ->
        :error

      not String.starts_with?(normalized, "/") ->
        :error

      normalized != "/" <> String.trim_trailing(site_path, "/") and site_path != "" ->
        :error

      not Regex.match?(~r/^[a-zA-Z0-9_\-\.\/]*$/, site_path) ->
        :error

      true ->
        {:ok, site_path}
    end
  end

  defp critical_platform_path?(path) do
    String.starts_with?(path, "live") or
      String.starts_with?(path, "socket") or
      String.starts_with?(path, "phoenix") or
      String.starts_with?(path, "profiles/") or
      String.starts_with?(path, "uploads") or
      String.starts_with?(path, "users/") or
      String.starts_with?(path, "relay") or
      String.starts_with?(path, "nodeinfo") or
      path == "inbox"
  end
end
