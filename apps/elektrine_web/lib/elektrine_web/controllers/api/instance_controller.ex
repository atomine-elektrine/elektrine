defmodule ElektrineWeb.API.InstanceController do
  @moduledoc """
  Public instance metadata for Mastodon API-compatible clients.
  """

  use ElektrineWeb, :controller

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Instance
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.System
  alias ElektrineWeb.CanonicalURL

  @max_status_chars 5_000
  @max_media_attachments 4
  @characters_reserved_per_url 23
  @supported_mime_types [
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
    "video/mp4",
    "video/webm",
    "audio/mpeg",
    "audio/ogg",
    "audio/wav"
  ]

  def show_v1(conn, _params) do
    metadata = metadata(conn)

    json(conn, %{
      uri: metadata.domain,
      title: metadata.title,
      short_description: metadata.short_description,
      description: metadata.description,
      email: metadata.email,
      version: metadata.version,
      urls: %{},
      stats: %{
        user_count: metadata.user_count,
        status_count: metadata.status_count,
        domain_count: 0
      },
      thumbnail: metadata.thumbnail,
      languages: metadata.languages,
      registrations: metadata.registrations_enabled,
      approval_required: true,
      invites_enabled: System.invite_codes_enabled?(),
      configuration: configuration(metadata.upload_limit),
      contact_account: nil,
      rules: [],
      max_toot_chars: @max_status_chars,
      max_media_attachments: @max_media_attachments,
      poll_limits: configuration(metadata.upload_limit).polls,
      upload_limit: metadata.upload_limit,
      pleroma: pleroma_configuration(metadata)
    })
  end

  def show_v2(conn, _params) do
    metadata = metadata(conn)

    json(conn, %{
      domain: metadata.domain,
      title: metadata.title,
      version: metadata.version,
      source_url: "https://github.com/atomine-elektrine/elektrine",
      description: metadata.description,
      usage: %{
        users: %{active_month: metadata.active_user_count}
      },
      thumbnail: %{
        url: metadata.thumbnail,
        blurhash: nil,
        versions: %{}
      },
      languages: metadata.languages,
      configuration: configuration(metadata.upload_limit),
      registrations: %{
        enabled: metadata.registrations_enabled,
        approval_required: true,
        message: nil
      },
      contact: %{
        email: metadata.email,
        account: nil
      },
      rules: [],
      pleroma: pleroma_configuration(metadata)
    })
  end

  def peers(conn, _params) do
    json(conn, peer_domains())
  end

  def rules(conn, _params) do
    json(conn, instance_rules())
  end

  def domain_blocks(conn, _params) do
    blocks =
      Instance
      |> where([instance], instance.blocked == true or instance.silenced == true)
      |> order_by([instance], asc: instance.domain)
      |> Repo.all()
      |> Enum.map(&format_domain_block/1)

    json(conn, blocks)
  end

  def translation_languages(conn, _params) do
    json(conn, %{})
  end

  defp metadata(conn) do
    domain = normalize_domain(conn.host)
    base_url = CanonicalURL.request_url(conn, "/", nil)

    %{
      domain: domain,
      title: "Elektrine",
      short_description: "Portable personal internet OS.",
      description:
        "Elektrine provides identity, social, mail, DNS, storage, and private apps for personal domains.",
      email: "support@#{domain}",
      version: version(),
      thumbnail: base_url <> "images/og-image.png",
      languages: ["en"],
      upload_limit: upload_limit(),
      registrations_enabled: !System.invite_codes_enabled?(),
      user_count: user_count(),
      active_user_count: active_user_count(),
      status_count: status_count()
    }
  end

  defp peer_domains do
    actor_domains =
      Actor
      |> where([actor], not is_nil(actor.domain))
      |> select([actor], actor.domain)
      |> distinct(true)
      |> Repo.all()

    instance_domains =
      Instance
      |> where([instance], not is_nil(instance.domain))
      |> select([instance], instance.domain)
      |> distinct(true)
      |> Repo.all()

    (actor_domains ++ instance_domains)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.sort()
  rescue
    _ -> []
  end

  defp instance_rules do
    :elektrine
    |> Application.get_env(:instance_rules, [])
    |> Enum.with_index(1)
    |> Enum.map(fn {rule, index} -> format_rule(rule, index) end)
  end

  defp format_rule(rule, index) when is_binary(rule) do
    %{id: to_string(index), text: rule, hint: ""}
  end

  defp format_rule(rule, index) when is_map(rule) do
    %{
      id: to_string(Map.get(rule, :id) || Map.get(rule, "id") || index),
      text: Map.get(rule, :text) || Map.get(rule, "text") || "",
      hint: Map.get(rule, :hint) || Map.get(rule, "hint") || ""
    }
  end

  defp format_rule(_rule, index), do: %{id: to_string(index), text: "", hint: ""}

  defp format_domain_block(%Instance{} = instance) do
    block = %{
      domain: instance.domain,
      digest: domain_digest(instance.domain),
      severity: domain_block_severity(instance)
    }

    if instance.reason && instance.reason != "" do
      Map.put(block, :comment, instance.reason)
    else
      block
    end
  end

  defp domain_block_severity(%Instance{blocked: true}), do: "suspend"
  defp domain_block_severity(%Instance{silenced: true}), do: "silence"
  defp domain_block_severity(_instance), do: "noop"

  defp domain_digest(domain) when is_binary(domain) do
    :sha256
    |> :crypto.hash(domain)
    |> Base.encode16(case: :lower)
  end

  defp domain_digest(_domain), do: nil

  defp configuration(upload_limit) do
    %{
      statuses: %{
        max_characters: @max_status_chars,
        max_media_attachments: @max_media_attachments,
        characters_reserved_per_url: @characters_reserved_per_url
      },
      media_attachments: %{
        supported_mime_types: @supported_mime_types,
        image_size_limit: upload_limit,
        image_matrix_limit: 16_777_216,
        video_size_limit: upload_limit,
        video_frame_rate_limit: 60,
        video_matrix_limit: 2_304_000
      },
      polls: %{
        max_options: 4,
        max_characters_per_option: 100,
        min_expiration: 300,
        max_expiration: 2_629_746
      },
      translation: %{enabled: false}
    }
  end

  defp pleroma_configuration(metadata) do
    %{
      metadata: %{
        account_activation_required: true,
        features: instance_features(),
        federation: %{},
        fields_limits: %{
          max_fields: 4,
          max_remote_fields: 20,
          name_length: 255,
          value_length: 2_048
        },
        post_formats: ["text/plain", "text/html"],
        birthday_required: false,
        birthday_min_age: nil,
        translation: %{},
        base_urls: %{
          upload: ElektrineWeb.Endpoint.url()
        },
        markup: %{
          allow_headings: false,
          allow_tables: false,
          allow_fonts: false,
          scrub_policy: "default"
        }
      },
      stats: %{mau: metadata.active_user_count},
      vapid_public_key: nil
    }
  end

  defp instance_features do
    [
      "pleroma_api",
      "mastodon_api",
      "polls",
      "v2_suggestions",
      "multifetch",
      "pleroma:api/v1/notifications:include_types_filter",
      "editing",
      "quote_posting",
      "pleroma_emoji_reactions",
      "pleroma_custom_emoji_reactions",
      "pleroma_chat_messages",
      "pleroma:pin_chats",
      "pleroma:get:main/ostatus",
      "pleroma:group_actors",
      "pleroma:bookmark_folders",
      "pleroma:block_expiration",
      "profile_directory"
    ]
  end

  defp user_count do
    Repo.aggregate(User, :count, :id)
  rescue
    _ -> 0
  end

  defp active_user_count do
    cutoff = DateTime.add(DateTime.utc_now(), -30, :day)

    Repo.aggregate(from(u in User, where: u.last_seen_at >= ^cutoff), :count, :id)
  rescue
    _ -> 0
  end

  defp status_count do
    Repo.aggregate(
      from(m in Message,
        where: is_nil(m.deleted_at),
        where: m.message_type == "social" or m.message_type == "post"
      ),
      :count,
      :id
    )
  rescue
    _ -> 0
  end

  defp upload_limit do
    :elektrine
    |> Application.get_env(:uploads, [])
    |> Keyword.get(:max_file_size, 5 * 1024 * 1024)
  end

  defp version do
    case Application.spec(:elektrine, :vsn) do
      nil -> "0.0.0"
      version -> List.to_string(version)
    end
  end

  defp normalize_domain(host) when is_binary(host) and host != "", do: String.downcase(host)
  defp normalize_domain(_host), do: "localhost"
end
