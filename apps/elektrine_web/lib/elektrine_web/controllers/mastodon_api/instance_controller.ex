defmodule ElektrineWeb.MastodonAPI.InstanceController do
  @moduledoc """
  Controller for Mastodon API instance information.

  Provides server information including supported features, limits, and configuration.

  ## Endpoints

  * `GET /api/v1/instance` - Get instance information (v1)
  * `GET /api/v2/instance` - Get instance information (v2)
  * `GET /api/v1/instance/peers` - Get known peers
  * `GET /api/v1/instance/activity` - Get weekly activity stats
  * `GET /api/v1/instance/rules` - Get instance rules
  """

  use ElektrineWeb, :controller

  alias Elektrine.Accounts

  import Ecto.Query

  @doc """
  GET /api/v1/instance

  Returns information about the instance.
  """
  def show(conn, _params) do
    instance = build_instance_v1()
    json(conn, instance)
  end

  @doc """
  GET /api/v2/instance

  Returns information about the instance (v2 format).
  """
  def show_v2(conn, _params) do
    instance = build_instance_v2()
    json(conn, instance)
  end

  @doc """
  GET /api/v1/instance/peers

  Returns list of known peers (federated instances).
  """
  def peers(conn, _params) do
    # Get unique domains from known instances
    peers = get_known_peers()
    json(conn, peers)
  end

  @doc """
  GET /api/v1/instance/activity

  Returns weekly activity statistics.
  """
  def activity(conn, _params) do
    activity = build_activity_stats()
    json(conn, activity)
  end

  @doc """
  GET /api/v1/instance/rules

  Returns the instance rules.
  """
  def rules(conn, _params) do
    rules = get_instance_rules()
    json(conn, rules)
  end

  # Private functions

  defp build_instance_v1 do
    config = get_instance_config()

    %{
      uri: config.domain,
      title: config.name,
      short_description: config.short_description,
      description: config.description,
      email: config.email,
      version: get_version_string(),
      urls: %{
        streaming_api: get_streaming_url()
      },
      stats: get_stats(),
      thumbnail: config.thumbnail,
      languages: config.languages,
      registrations: config.registrations_open,
      approval_required: config.approval_required,
      invites_enabled: config.invites_enabled,
      configuration: get_configuration(),
      contact_account: get_contact_account(),
      rules: get_instance_rules()
    }
  end

  defp build_instance_v2 do
    config = get_instance_config()

    %{
      domain: config.domain,
      title: config.name,
      version: get_version_string(),
      source_url: "https://github.com/anomalyco/elektrine",
      description: config.description,
      usage: %{
        users: %{
          active_month: get_active_users_count()
        }
      },
      thumbnail: %{
        url: config.thumbnail,
        blurhash: nil,
        versions: %{}
      },
      languages: config.languages,
      configuration: get_configuration_v2(),
      registrations: %{
        enabled: config.registrations_open,
        approval_required: config.approval_required,
        message: nil
      },
      contact: %{
        email: config.email,
        account: get_contact_account()
      },
      rules: get_instance_rules()
    }
  end

  defp get_instance_config do
    domain = ElektrineWeb.Endpoint.host()

    %{
      domain: domain,
      name: Application.get_env(:elektrine, :instance_name, "Elektrine"),
      short_description: Application.get_env(:elektrine, :instance_short_description, ""),
      description:
        Application.get_env(:elektrine, :instance_description, "An Elektrine instance"),
      email: Application.get_env(:elektrine, :instance_email, "admin@#{domain}"),
      thumbnail: Application.get_env(:elektrine, :instance_thumbnail, nil),
      languages: Application.get_env(:elektrine, :instance_languages, ["en"]),
      registrations_open: Application.get_env(:elektrine, :registrations_open, true),
      approval_required: Application.get_env(:elektrine, :approval_required, false),
      invites_enabled: Application.get_env(:elektrine, :invites_enabled, true)
    }
  end

  defp get_version_string do
    # Mastodon compatibility version + Elektrine version
    elektrine_version = Application.spec(:elektrine, :vsn) || "0.1.0"
    "4.2.0 (compatible; Elektrine #{elektrine_version})"
  end

  defp get_streaming_url do
    endpoint = ElektrineWeb.Endpoint
    scheme = if endpoint.config(:https), do: "wss", else: "ws"
    "#{scheme}://#{endpoint.host()}"
  end

  defp get_stats do
    %{
      user_count: count_users(),
      status_count: count_posts(),
      domain_count: get_known_peers() |> length()
    }
  end

  defp count_users do
    Elektrine.Repo.aggregate(Elektrine.Accounts.User, :count, :id)
  rescue
    _ -> 0
  end

  defp count_posts do
    # Count all posts
    Elektrine.Repo.aggregate(Elektrine.Messaging.Post, :count, :id)
  rescue
    _ -> 0
  end

  defp get_known_peers do
    # Get unique domains from instances table
    Elektrine.Repo.all(
      from(i in "instances",
        select: i.domain,
        distinct: true
      )
    )
  rescue
    _ -> []
  end

  defp get_active_users_count do
    # Count users active in the last 30 days
    cutoff = DateTime.add(DateTime.utc_now(), -30 * 24 * 60 * 60, :second)

    Elektrine.Repo.one(
      from(u in Elektrine.Accounts.User,
        where: u.last_login_at > ^cutoff,
        select: count(u.id)
      )
    ) || 0
  rescue
    _ -> 0
  end

  defp get_configuration do
    %{
      statuses: %{
        max_characters: 5000,
        max_media_attachments: 4,
        characters_reserved_per_url: 23
      },
      media_attachments: %{
        supported_mime_types: [
          "image/jpeg",
          "image/png",
          "image/gif",
          "image/webp",
          "video/webm",
          "video/mp4",
          "video/quicktime",
          "video/ogg",
          "audio/wave",
          "audio/wav",
          "audio/x-wav",
          "audio/x-pn-wave",
          "audio/vnd.wave",
          "audio/ogg",
          "audio/vorbis",
          "audio/mpeg",
          "audio/mp3",
          "audio/webm",
          "audio/flac",
          "audio/aac",
          "audio/m4a",
          "audio/x-m4a",
          "audio/mp4",
          "audio/3gpp"
        ],
        image_size_limit: 16 * 1024 * 1024,
        image_matrix_limit: 33_177_600,
        video_size_limit: 99 * 1024 * 1024,
        video_frame_rate_limit: 120,
        video_matrix_limit: 8_294_400
      },
      polls: %{
        max_options: 4,
        max_characters_per_option: 50,
        min_expiration: 300,
        max_expiration: 2_629_746
      }
    }
  end

  defp get_configuration_v2 do
    base = get_configuration()

    Map.merge(base, %{
      urls: %{
        streaming: get_streaming_url()
      },
      accounts: %{
        max_featured_tags: 10
      },
      translation: %{
        enabled: false
      }
    })
  end

  defp get_contact_account do
    # Return the admin contact account
    case Application.get_env(:elektrine, :instance_admin_username) do
      nil ->
        nil

      username ->
        case Accounts.get_user_by_username(username) do
          nil -> nil
          user -> render_account_minimal(user)
        end
    end
  end

  defp render_account_minimal(user) do
    base_url = ElektrineWeb.Endpoint.url()

    %{
      id: to_string(user.id),
      username: user.username,
      acct: user.username,
      display_name: user.display_name || user.username,
      url: "#{base_url}/#{user.username}",
      avatar: Elektrine.Uploads.avatar_url(user.avatar),
      avatar_static: Elektrine.Uploads.avatar_url(user.avatar),
      header: Elektrine.Uploads.background_url(user.background),
      header_static: Elektrine.Uploads.background_url(user.background)
    }
  end

  defp get_instance_rules do
    # Return instance rules
    # These would be configured in the admin panel
    Application.get_env(:elektrine, :instance_rules, [])
    |> Enum.with_index(1)
    |> Enum.map(fn {rule, index} ->
      %{
        id: to_string(index),
        text: rule
      }
    end)
  end

  defp build_activity_stats do
    # Return last 12 weeks of activity
    now = Date.utc_today()

    Enum.map(0..11, fn weeks_ago ->
      end_date = Date.add(now, -7 * weeks_ago)
      start_date = Date.add(end_date, -7)

      # Convert Date to Unix timestamp (midnight of that day)
      start_datetime = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")
      week_timestamp = DateTime.to_unix(start_datetime)

      %{
        week: to_string(week_timestamp),
        statuses: to_string(count_posts_in_range(start_date, end_date)),
        logins: to_string(count_logins_in_range(start_date, end_date)),
        registrations: to_string(count_registrations_in_range(start_date, end_date))
      }
    end)
  end

  defp count_posts_in_range(start_date, end_date) do
    start_dt = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")
    end_dt = DateTime.new!(end_date, ~T[23:59:59], "Etc/UTC")

    Elektrine.Repo.one(
      from(p in "posts",
        where: p.inserted_at >= ^start_dt and p.inserted_at <= ^end_dt,
        select: count(p.id)
      )
    ) || 0
  rescue
    _ -> 0
  end

  defp count_logins_in_range(_start_date, _end_date) do
    # This would require tracking login activity
    0
  end

  defp count_registrations_in_range(start_date, end_date) do
    start_dt = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")
    end_dt = DateTime.new!(end_date, ~T[23:59:59], "Etc/UTC")

    Elektrine.Repo.one(
      from(u in Elektrine.Accounts.User,
        where: u.inserted_at >= ^start_dt and u.inserted_at <= ^end_dt,
        select: count(u.id)
      )
    ) || 0
  rescue
    _ -> 0
  end
end
