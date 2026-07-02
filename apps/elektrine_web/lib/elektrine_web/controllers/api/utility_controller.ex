defmodule ElektrineWeb.API.UtilityController do
  @moduledoc """
  Public utility endpoints for API clients.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.DomainMigration
  alias Elektrine.Captcha
  alias Elektrine.Emojis
  alias Elektrine.Repo

  @captcha_seconds_valid 300

  def frontend_configurations(conn, _params) do
    configurations =
      :elektrine
      |> Application.get_env(:frontend_configurations, %{})
      |> normalize_configurations()

    json(conn, configurations)
  end

  def available_frontends(conn, _params) do
    frontends =
      :elektrine
      |> Application.get_env(:frontends, [])
      |> Keyword.get(:pickable, [])
      |> normalize_frontends()

    json(conn, frontends)
  end

  def update_preferred_frontend(conn, %{"frontend_name" => frontend_name})
      when is_binary(frontend_name) do
    conn
    |> put_resp_cookie("preferred_frontend", frontend_name,
      path: "/",
      same_site: "Lax",
      secure: conn.scheme == :https,
      max_age: 365 * 24 * 60 * 60
    )
    |> json(%{frontend_name: frontend_name})
  end

  def update_preferred_frontend(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "frontend_name is required"})
  end

  def list_aliases(conn, _params) do
    user = conn.assigns[:current_user]
    json(conn, %{aliases: user_aliases(user)})
  end

  def add_alias(conn, params) do
    user = conn.assigns[:current_user]

    with %User{} <- user,
         {:ok, alias_value} <- alias_param(params),
         aliases <- Enum.uniq(user_aliases(user) ++ [alias_value]),
         {:ok, _updated_user} <- Accounts.update_user(user, %{also_known_as: aliases}) do
      json(conn, %{status: "success"})
    else
      nil ->
        unauthorized(conn)

      {:error, :missing_alias} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "alias is required"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_alias", details: translate_errors(changeset)})
    end
  end

  def delete_alias(conn, params) do
    user = conn.assigns[:current_user]

    with %User{} <- user,
         {:ok, alias_value} <- alias_param(params) do
      aliases = user_aliases(user)

      if alias_value in aliases do
        {:ok, _updated_user} =
          Accounts.update_user(user, %{also_known_as: List.delete(aliases, alias_value)})

        json(conn, %{status: "success"})
      else
        conn
        |> put_status(:not_found)
        |> json(%{error: "Account has no such alias."})
      end
    else
      nil ->
        unauthorized(conn)

      {:error, :missing_alias} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "alias is required"})
    end
  end

  def move_account(conn, params) do
    user = conn.assigns[:current_user]

    with %User{} <- user,
         {:ok, target_account} <- move_target_param(params),
         {:ok, password} <- password_param(params),
         {:ok, _user} <- Accounts.verify_user_password(user, password),
         {:ok, _summary} <- DomainMigration.move_account(user, target_account) do
      json(conn, %{status: "success"})
    else
      nil ->
        unauthorized(conn)

      {:error, :missing_move_target} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "target_account is required"})

      {:error, :missing_password} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "password is required"})

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "invalid_password"})

      {:error, :move_target_not_verified} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "move_target_not_verified"})

      {:error, reason}
      when reason in [:invalid_move_target, :not_found, :webfinger_failed, :no_actor_link] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_move_target"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_move_target", details: translate_errors(changeset)})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_move_target"})
    end
  end

  def emoji(conn, _params) do
    emojis =
      Emojis.list_public_picker_emojis()
      |> Map.new(fn emoji ->
        {emoji.shortcode,
         %{
           image_url: emoji.image_url,
           tags: emoji_tags(emoji)
         }}
      end)

    json(conn, emojis)
  end

  def captcha(conn, _params) do
    {image_binary, _answer, token} = Captcha.generate()

    json(conn, %{
      type: "native",
      token: token,
      answer_data: token,
      url: "data:image/png;base64,#{Base.encode64(image_binary)}",
      seconds_valid: @captcha_seconds_valid
    })
  end

  def healthcheck(conn, _params) do
    case Repo.query("SELECT 1", [], timeout: 1_000, pool_timeout: 1_000) do
      {:ok, _result} ->
        json(conn, %{
          healthy: true,
          database: "ok",
          memory_used: :erlang.memory(:total),
          schedulers: :erlang.system_info(:schedulers_online)
        })

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{healthy: false, database: "error", reason: inspect(reason)})
    end
  end

  defp normalize_configurations(configurations) when is_map(configurations), do: configurations

  defp normalize_configurations(configurations) when is_list(configurations) do
    Enum.into(configurations, %{}, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_configurations(_), do: %{}

  defp normalize_frontends(frontends) when is_list(frontends) do
    Enum.filter(frontends, &is_binary/1)
  end

  defp normalize_frontends(_frontends), do: []

  defp alias_param(params) do
    value = params["alias"] || params[:alias] || params["account"] || params[:account]

    case normalize_alias(value) do
      nil -> {:error, :missing_alias}
      alias_value -> {:ok, alias_value}
    end
  end

  defp normalize_alias(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_alias(_value), do: nil

  defp move_target_param(params) do
    value =
      params["target_account"] ||
        params[:target_account] ||
        params["target"] ||
        params[:target] ||
        params["moved_to"] ||
        params[:moved_to]

    case normalize_move_target(value) do
      nil -> {:error, :missing_move_target}
      target_account -> {:ok, target_account}
    end
  end

  defp normalize_move_target(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      String.starts_with?(value, ["http://", "https://", "acct:"]) ->
        value

      String.contains?(value, "@") ->
        "acct:#{value}"

      true ->
        value
    end
  end

  defp normalize_move_target(_value), do: nil

  defp password_param(params) do
    value = params["password"] || params[:password]

    case normalize_password(value) do
      nil -> {:error, :missing_password}
      password -> {:ok, password}
    end
  end

  defp normalize_password(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_password(_value), do: nil

  defp user_aliases(%User{also_known_as: aliases}) when is_list(aliases), do: aliases
  defp user_aliases(_user), do: []

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthenticated"})
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp emoji_tags(%{category: category}) when is_binary(category) and category != "",
    do: [category]

  defp emoji_tags(_emoji), do: []
end
