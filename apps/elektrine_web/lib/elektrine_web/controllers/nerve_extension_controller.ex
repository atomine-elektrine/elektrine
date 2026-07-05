defmodule ElektrineWeb.NerveExtensionController do
  use ElektrineWeb, :controller

  alias Elektrine.Developer
  alias Elektrine.Theme

  @source_extension_dir Path.expand("../../../../../clients/nerve-extension", __DIR__)
  @allowed_https_return_hosts [
    "chromiumapp.org",
    "extensions.allizom.org"
  ]
  @pairing_ttl_ms :timer.minutes(5)

  def connect(conn, %{"pairing_id" => pairing_id, "pairing_secret" => pairing_secret} = params) do
    case validate_pairing(pairing_id, pairing_secret) do
      {:ok, pairing} ->
        conn
        |> put_resp_content_type("text/html")
        |> html(connect_page(conn, Map.merge(pairing, %{state: Map.get(params, "state")})))

      :error ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid extension pairing request")
    end
  end

  def connect(conn, %{"return_to" => return_to} = params) do
    case validate_return_to(return_to) do
      {:ok, return_to} ->
        conn
        |> put_resp_content_type("text/html")
        |> html(connect_page(conn, %{return_to: return_to, state: Map.get(params, "state")}))

      :error ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid extension return URL")
    end
  end

  def connect(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> text("Missing extension return URL")
  end

  def authorize(conn, %{"pairing_id" => pairing_id, "pairing_secret" => pairing_secret}) do
    user = conn.assigns.current_user

    with {:ok, pairing} <- validate_pairing(pairing_id, pairing_secret),
         {:ok, api_token} <- create_extension_token(user),
         :ok <- store_pairing_token(pairing, user, api_token.token) do
      conn
      |> put_resp_content_type("text/html")
      |> html(connected_page(user))
    else
      :error ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid extension pairing request")

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> text("Could not create extension token. Revoke an old API token and try again.")
    end
  end

  def authorize(conn, %{"return_to" => return_to} = params) do
    user = conn.assigns.current_user

    with {:ok, return_to} <- validate_return_to(return_to),
         {:ok, api_token} <- create_extension_token(user) do
      redirect(conn,
        external: callback_url(return_to, user, api_token.token, Map.get(params, "state"))
      )
    else
      :error ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid extension return URL")

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> text("Could not create extension token. Revoke an old API token and try again.")
    end
  end

  def connect_status(conn, %{"id" => pairing_id, "secret" => pairing_secret}) do
    with {:ok, pairing} <- validate_pairing(pairing_id, pairing_secret),
         {:ok, payload} <- fetch_pairing_token(pairing) do
      json(conn, %{status: "connected", token: payload.token, user: payload.user})
    else
      :pending ->
        conn
        |> put_status(:accepted)
        |> json(%{status: "pending"})

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid extension pairing request"})
    end
  end

  def connect_status(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing extension pairing secret"})
  end

  def download(conn, %{"browser" => browser}) do
    with {:ok, filename, content_type} <- download_metadata(browser),
         {:ok, archive} <- build_archive() do
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"#{filename}\""
      )
      |> send_resp(200, archive)
    else
      :error ->
        send_resp(conn, 404, "Not found")

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> text("Failed to package browser extension: #{inspect(reason)}")
    end
  end

  defp download_metadata("chromium") do
    {:ok, "elektrine-nerve-extension-chromium.zip", "application/zip"}
  end

  defp download_metadata("firefox") do
    {:ok, "elektrine-nerve-extension-firefox.xpi", "application/x-xpinstall"}
  end

  defp download_metadata(_browser), do: :error

  defp create_extension_token(user) do
    Developer.create_nerve_extension_token(user.id)
  end

  defp callback_url(return_to, user, token, state) do
    uri = URI.parse(return_to)

    fragment =
      %{
        token: token,
        token_type: "pat",
        username: user.username,
        theme: Jason.encode!(Theme.api_payload(user)),
        state: state
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> URI.encode_query()

    %{uri | fragment: fragment}
    |> URI.to_string()
  end

  defp store_pairing_token(%{id: pairing_id, secret_hash: secret_hash}, user, token) do
    payload = %{
      secret_hash: secret_hash,
      token: token,
      user: %{
        username: user.username,
        theme: Theme.api_payload(user)
      }
    }

    case Cachex.put(:app_cache, pairing_cache_key(pairing_id), payload, ttl: @pairing_ttl_ms) do
      {:ok, true} -> :ok
      _ -> :error
    end
  end

  defp fetch_pairing_token(%{id: pairing_id, secret_hash: secret_hash}) do
    key = pairing_cache_key(pairing_id)

    case Cachex.get(:app_cache, key) do
      {:ok, %{secret_hash: ^secret_hash} = payload} ->
        _ = Cachex.del(:app_cache, key)
        {:ok, payload}

      {:ok, nil} ->
        :pending

      _ ->
        :error
    end
  end

  defp validate_return_to(value) when is_binary(value) do
    uri = URI.parse(value)

    cond do
      uri.scheme in ["chrome-extension", "moz-extension"] and present?(uri.host) ->
        {:ok, URI.to_string(uri)}

      uri.scheme == "https" and allowed_https_return_host?(uri.host) ->
        {:ok, URI.to_string(uri)}

      true ->
        :error
    end
  rescue
    _ -> :error
  end

  defp validate_return_to(_value), do: :error

  defp validate_pairing(pairing_id, pairing_secret)
       when is_binary(pairing_id) and is_binary(pairing_secret) do
    cond do
      not Regex.match?(~r/\A[a-f0-9]{32}\z/, pairing_id) ->
        :error

      not Regex.match?(~r/\A[a-f0-9]{64}\z/, pairing_secret) ->
        :error

      true ->
        {:ok,
         %{
           id: pairing_id,
           secret: pairing_secret,
           secret_hash: hash_pairing_secret(pairing_secret)
         }}
    end
  end

  defp validate_pairing(_pairing_id, _pairing_secret), do: :error

  defp allowed_https_return_host?(host) when is_binary(host) do
    Enum.any?(@allowed_https_return_hosts, fn allowed ->
      host == allowed or String.ends_with?(host, ".#{allowed}")
    end)
  end

  defp allowed_https_return_host?(_host), do: false

  defp connect_page(conn, assigns) do
    username = conn.assigns.current_user.username
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    """
    <!doctype html>
    <html lang="en" data-theme="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Connect Nerve Extension</title>
        <style>
          :root { color-scheme: dark; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #121214; color: #e5e2e1; }
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px; background: #121214; }
          main { width: min(100%, 440px); border: 1px solid #2a2a31; border-radius: 14px; background: #1a1a1d; padding: 20px; box-shadow: 0 24px 54px -36px rgba(2, 12, 30, 0.88); }
          h1 { margin: 0; font-size: 22px; line-height: 1.1; }
          p { margin: 10px 0 0; color: rgba(229, 226, 225, 0.78); line-height: 1.45; }
          .actions { display: flex; gap: 10px; margin-top: 18px; }
          button, a { min-height: 40px; display: inline-flex; align-items: center; justify-content: center; border-radius: 10px; padding: 0 14px; font-weight: 650; text-decoration: none; }
          button { border: 1px solid color-mix(in srgb, #2a2a31 68%, #5f87b8 32%); background: color-mix(in srgb, #2a2a31 72%, #5f87b8 28%); color: #e5e2e1; cursor: pointer; }
          a { border: 1px solid #2a2a31; color: #e5e2e1; }
          .eyebrow { display: block; margin-bottom: 8px; color: #8aa8ca; font-size: 11px; font-weight: 750; letter-spacing: .14em; text-transform: uppercase; }
        </style>
      </head>
      <body>
        <main>
          <span class="eyebrow">Nerve</span>
          <h1>Connect Browser Extension</h1>
          <p>Authorize this browser extension for #{escape_html(username)}. It will receive a scoped token for Nerve and Kairo capture.</p>
          <form method="post" action="/account/nerve/extension/connect">
            <input type="hidden" name="_csrf_token" value="#{escape_html(csrf_token)}" />
            #{connect_hidden_inputs(assigns)}
            <div class="actions">
              <button type="submit">Connect extension</button>
              <a href="/account/nerve">Cancel</a>
            </div>
          </form>
        </main>
      </body>
    </html>
    """
  end

  defp connected_page(user) do
    """
    <!doctype html>
    <html lang="en" data-theme="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Nerve Extension Connected</title>
        <style>
          :root { color-scheme: dark; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #121214; color: #e5e2e1; }
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px; background: #121214; }
          main { width: min(100%, 420px); border: 1px solid #2a2a31; border-radius: 14px; background: #1a1a1d; padding: 20px; box-shadow: 0 24px 54px -36px rgba(2, 12, 30, 0.88); }
          h1 { margin: 0; font-size: 22px; line-height: 1.1; }
          p { margin: 10px 0 0; color: rgba(229, 226, 225, 0.78); line-height: 1.45; }
          .eyebrow { display: block; margin-bottom: 8px; color: #8aa8ca; font-size: 11px; font-weight: 750; letter-spacing: .14em; text-transform: uppercase; }
        </style>
      </head>
      <body>
        <main>
          <span class="eyebrow">Nerve</span>
          <h1>Extension Connected</h1>
          <p>You can return to the extension settings. #{escape_html(user.username)} is connected for Nerve and Kairo capture.</p>
        </main>
      </body>
    </html>
    """
  end

  defp connect_hidden_inputs(%{return_to: return_to, state: state}) do
    """
    <input type="hidden" name="return_to" value="#{escape_html(return_to)}" />
    <input type="hidden" name="state" value="#{escape_html(state || "")}" />
    """
  end

  defp connect_hidden_inputs(%{id: pairing_id, secret: pairing_secret, state: state}) do
    """
    <input type="hidden" name="pairing_id" value="#{escape_html(pairing_id)}" />
    <input type="hidden" name="pairing_secret" value="#{escape_html(pairing_secret)}" />
    <input type="hidden" name="state" value="#{escape_html(state || "")}" />
    """
  end

  defp pairing_cache_key(pairing_id), do: {:nerve_extension_pairing, pairing_id}

  defp hash_pairing_secret(secret) do
    :sha256
    |> :crypto.hash(secret)
    |> Base.encode16(case: :lower)
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp escape_html(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp build_archive do
    with {:ok, extension_dir} <- extension_dir(),
         [_ | _] = files <- archive_files(extension_dir) do
      case :zip.create(~c"elektrine-nerve-extension.zip", files, [:memory]) do
        {:ok, {_name, archive}} -> {:ok, archive}
        {:error, reason} -> {:error, reason}
      end
    else
      [] -> {:error, :no_extension_files}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extension_dir do
    priv_extension_dir =
      case :code.priv_dir(:elektrine_web) do
        path when is_list(path) -> path |> List.to_string() |> Path.join("nerve-extension")
        {:error, _reason} -> nil
      end

    cond do
      is_binary(priv_extension_dir) and File.dir?(priv_extension_dir) ->
        {:ok, priv_extension_dir}

      File.dir?(@source_extension_dir) ->
        {:ok, @source_extension_dir}

      true ->
        {:error, :extension_files_missing}
    end
  end

  defp archive_files(extension_dir) do
    extension_dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn path ->
      relative_path = Path.relative_to(path, extension_dir)
      {String.to_charlist(relative_path), File.read!(path)}
    end)
  end
end
