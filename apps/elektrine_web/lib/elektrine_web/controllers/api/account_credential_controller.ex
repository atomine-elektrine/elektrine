defmodule ElektrineWeb.API.AccountCredentialController do
  @moduledoc """
  Current-account credential endpoints for compatible social clients.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Profiles
  alias ElektrineWeb.API.AccountJSON

  def verify_credentials(conn, _params) do
    user = conn.assigns[:current_user]

    json(conn, format_credential_account(user))
  end

  def update_credentials(conn, params) do
    user = conn.assigns[:current_user]

    with {:ok, updated_user} <- update_user_settings(user, params),
         {:ok, _profile} <- update_profile_settings(updated_user, params) do
      json(conn, format_credential_account(updated_user))
    else
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_account_metadata", details: translate_errors(changeset)})
    end
  end

  defp update_user_settings(%User{} = user, params) do
    attrs =
      %{}
      |> put_if_present(:display_name, params["display_name"])
      |> put_param_if_present(params, "avatar", :avatar, &empty_string_to_nil/1)
      |> put_param_if_present(params, "birthday", :birthday, &empty_string_to_nil/1)
      |> put_account_migration_params(params)
      |> put_if_present(:activitypub_manually_approve_followers, truthy_param(params["locked"]))
      |> put_if_present(:show_birthday, truthy_param(params["show_birthday"]))
      |> put_if_present(:hide_followers, truthy_param(params["hide_followers"]))
      |> put_if_present(:hide_follows, truthy_param(params["hide_follows"]))
      |> put_if_present(:hide_favorites, truthy_param(params["hide_favorites"]))
      |> put_if_present(
        :default_post_visibility,
        normalize_privacy(source_param(params, "privacy"))
      )

    if attrs == %{} do
      {:ok, user}
    else
      Accounts.update_user(user, attrs)
    end
  end

  defp update_profile_settings(%User{} = user, params) do
    attrs =
      %{}
      |> put_if_present(:display_name, params["display_name"])
      |> put_if_present(:description, params["note"])
      |> put_param_if_present(params, "avatar", :avatar_url, &empty_string_to_nil/1)
      |> put_param_if_present(params, "header", :banner_url, &empty_string_to_nil/1)

    if attrs == %{} do
      {:ok, Profiles.get_user_profile(user.id)}
    else
      Profiles.upsert_user_profile(user.id, attrs)
    end
  end

  defp format_credential_account(%User{} = user) do
    profile = Profiles.get_user_profile(user.id)
    acct = user.handle || user.username
    note = profile && profile.description
    header = profile && profile.banner_url
    avatar = user.avatar || (profile && profile.avatar_url)

    %{
      id: to_string(user.id),
      username: user.username,
      acct: acct,
      display_name: user.display_name || user.username,
      note: note || "",
      url: Elektrine.Domains.profile_url_for_user(user) || "/#{acct}",
      avatar: avatar,
      avatar_static: avatar,
      header: header,
      header_static: header,
      fields: [],
      emojis: [],
      locked: user.activitypub_manually_approve_followers || false,
      bot: false,
      discoverable: user.profile_visibility != "private",
      followers_count: AccountJSON.visible_followers_count(user, user),
      following_count: AccountJSON.visible_following_count(user, user),
      statuses_count: AccountJSON.statuses_count(user),
      last_status_at: AccountJSON.last_status_at(user),
      created_at: user.inserted_at,
      remote: false,
      pleroma: %{
        birthday: user.birthday,
        also_known_as: user.also_known_as || [],
        moved_to: user.moved_to,
        hide_followers: user.hide_followers || false,
        hide_follows: user.hide_follows || false,
        hide_favorites: user.hide_favorites || false
      },
      source: %{
        note: note || "",
        fields: [],
        privacy: user.default_post_visibility || "followers",
        sensitive: false,
        language: user.locale || "en",
        pleroma: %{
          show_birthday: user.show_birthday || false,
          hide_followers: user.hide_followers || false,
          hide_follows: user.hide_follows || false,
          hide_favorites: user.hide_favorites || false
        },
        follow_requests_count: Profiles.count_pending_follow_requests(user.id)
      }
    }
  end

  defp put_if_present(attrs, _key, nil), do: attrs
  defp put_if_present(attrs, _key, ""), do: attrs
  defp put_if_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp put_param_if_present(attrs, params, param_key, attr_key, fun) do
    if Map.has_key?(params, param_key) do
      Map.put(attrs, attr_key, fun.(Map.get(params, param_key)))
    else
      attrs
    end
  end

  defp empty_string_to_nil(""), do: nil
  defp empty_string_to_nil(value), do: value

  defp put_account_migration_params(attrs, params) do
    attrs
    |> put_param_if_present(params, "also_known_as", :also_known_as, &normalize_alias_param/1)
    |> put_param_if_present(params, "alsoKnownAs", :also_known_as, &normalize_alias_param/1)
    |> put_param_if_present(params, "moved_to", :moved_to, &empty_string_to_nil/1)
    |> put_param_if_present(params, "movedTo", :moved_to, &empty_string_to_nil/1)
  end

  defp normalize_alias_param(values) when is_list(values), do: values

  defp normalize_alias_param(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp normalize_alias_param(_value), do: []

  defp source_param(params, key) do
    source = params["source"] || params[:source] || %{}
    Map.get(source, key) || Map.get(source, String.to_atom(key))
  end

  defp normalize_privacy("unlisted"), do: "public"
  defp normalize_privacy("private"), do: "followers"
  defp normalize_privacy(value) when value in ["public", "followers", "friends"], do: value
  defp normalize_privacy(_value), do: nil

  defp truthy_param(nil), do: nil
  defp truthy_param(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy_param(value) when value in [false, "false", "0", 0, "off"], do: false
  defp truthy_param(_value), do: nil

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
