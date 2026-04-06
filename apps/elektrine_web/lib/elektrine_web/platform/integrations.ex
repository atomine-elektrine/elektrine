defmodule ElektrineWeb.Platform.Integrations do
  @moduledoc false

  import Ecto.Query, only: [dynamic: 1, dynamic: 2, from: 2]

  alias Elektrine.Platform.Modules

  @email_module :"Elixir.Elektrine.Email"
  @email_alias_module :"Elixir.Elektrine.Email.Alias"
  @email_unsubscribe_module :"Elixir.Elektrine.Email.Unsubscribe"
  @email_unsubscribes_module :"Elixir.Elektrine.Email.Unsubscribes"
  @email_list_types_module :"Elixir.Elektrine.Email.ListTypes"
  @email_message_module :"Elixir.Elektrine.Email.Message"
  @email_messages_module :"Elixir.Elektrine.Email.Messages"
  @email_rate_limiter_module :"Elixir.Elektrine.Email.RateLimiter"
  @email_mailbox_module :"Elixir.Elektrine.Email.Mailbox"
  @email_user_auth_module :"Elixir.ElektrineEmailWeb.UserAuthEmail"
  @email_user_settings_module :"Elixir.ElektrineEmailWeb.UserSettingsEmail"
  @email_user_settings_controller_module :"Elixir.ElektrineEmailWeb.UserSettingsEmailController"
  @email_storage_module :"Elixir.ElektrineEmailWeb.StorageEmail"
  @email_helpers_module :"Elixir.ElektrineEmailWeb.EmailLive.EmailHelpers"
  @email_display_module :"Elixir.ElektrineEmailWeb.Components.Email.Display"
  @social_module :"Elixir.Elektrine.Social"
  @social_poll_module :"Elixir.Elektrine.Social.Poll"
  @social_post_like_module :"Elixir.Elektrine.Social.PostLike"
  @social_post_boost_module :"Elixir.Elektrine.Social.PostBoost"
  @social_saved_item_module :"Elixir.Elektrine.Social.SavedItem"
  @social_link_preview_fetcher_module :"Elixir.Elektrine.Social.LinkPreviewFetcher"
  @social_recommendations_module :"Elixir.Elektrine.Social.Recommendations"
  @vpn_module :"Elixir.Elektrine.VPN"
  @password_manager_module :"Elixir.Elektrine.PasswordManager"
  @vault_entry_module :"Elixir.Elektrine.PasswordManager.VaultEntry"

  def email_available?, do: available?(:email, @email_module)
  def social_available?, do: available?(:social, @social_module)
  def vpn_available?, do: available?(:vpn, @vpn_module)
  def vault_available?, do: available?(:vault, @password_manager_module)
  def user_settings_email_component, do: optional_module(:email, @email_user_settings_module)

  def init_user_settings_email(socket) do
    case optional_module(:email, @email_user_settings_module) do
      nil ->
        assign_defaults(socket, user_settings_email_defaults())

      module ->
        module.init_assigns(socket)
    end
  end

  def load_user_settings_email(socket) do
    case optional_module(:email, @email_user_settings_module) do
      nil ->
        socket
        |> assign_defaults(user_settings_email_defaults())
        |> Phoenix.Component.assign(:loading_email, false)

      module ->
        module.load_email_data(socket)
    end
  end

  def handle_user_settings_email_event(event, params, socket) do
    case optional_module(:email, @email_user_settings_module) do
      nil -> {:handled, socket}
      module -> module.handle_event(event, params, socket)
    end
  end

  def edit_password_assigns(user_id) do
    call_optional(
      :email,
      @email_user_settings_controller_module,
      :edit_password_assigns,
      [user_id],
      %{private_mailbox: nil, private_mailbox_unlock_mode: "account_password"}
    )
  end

  def decode_private_mailbox_rewrap(params) do
    call_optional(
      :email,
      @email_user_settings_controller_module,
      :decode_private_mailbox_rewrap,
      [params],
      {:ok, nil}
    )
  end

  def email_restriction_status(user_id) do
    call_optional(
      :email,
      @email_rate_limiter_module,
      :get_restriction_status,
      [user_id],
      %{restricted: false}
    )
  end

  def email_mailboxes(user_id) do
    call_optional(:email, @email_module, :get_user_mailboxes, [user_id], [])
  end

  def email_aliases(user_id) do
    call_optional(:email, @email_module, :list_aliases, [user_id], [])
  end

  def email_mailbox(user_id) do
    call_optional(:email, @email_module, :get_user_mailbox, [user_id], nil)
  end

  def email_unread_counts(mailbox_id) do
    call_optional(:email, @email_messages_module, :get_all_unread_counts, [mailbox_id], %{})
  end

  def email_user_message(message_id, user_id) do
    call_optional(
      :email,
      @email_module,
      :get_user_message,
      [message_id, user_id],
      {:error, :not_found}
    )
  end

  def email_mark_as_read(message) do
    call_optional(:email, @email_module, :mark_as_read, [message], {:error, :unavailable})
  end

  def email_unread_count(mailbox_id) do
    call_optional(:email, @email_messages_module, :unread_count, [mailbox_id], 0)
  end

  def warm_user_auth_email_caches(user) do
    call_optional(:email, @email_user_auth_module, :warm_user_caches, [user], :ok)
  end

  def process_email_html(html_content) do
    call_optional(
      :email,
      @email_display_module,
      :process_email_html,
      [html_content],
      html_content
    )
  end

  def clean_email_artifacts(content) do
    call_optional(:email, @email_display_module, :clean_email_artifacts, [content], content)
  end

  def safe_sanitize_email_html(html_content) do
    call_optional(
      :email,
      @email_display_module,
      :safe_sanitize_email_html,
      [html_content],
      html_content
    )
  end

  def permissive_email_sanitize(html_content) do
    call_optional(
      :email,
      @email_display_module,
      :permissive_email_sanitize,
      [html_content],
      html_content
    )
  end

  def safe_message_to_json(message) do
    call_optional(:email, @email_display_module, :safe_message_to_json, [message], %{})
  end

  def decode_email_subject(subject) do
    call_optional(:email, @email_display_module, :decode_email_subject, [subject], subject)
  end

  def format_email_display(email_string) do
    call_optional(
      :email,
      @email_display_module,
      :format_email_display,
      [email_string],
      email_string
    )
  end

  def admin_custom_domain_stats(default \\ %{}) do
    call_optional(:email, @email_module, :custom_domain_admin_stats, [], default)
  end

  def admin_email_record_count(:mailboxes), do: aggregate_optional(@email_mailbox_module)
  def admin_email_record_count(:messages), do: aggregate_optional(@email_message_module)
  def admin_email_record_count(:aliases), do: aggregate_optional(@email_alias_module)
  def admin_email_record_count(_kind), do: 0

  def admin_aliases_by_user_ids([]), do: %{}

  def admin_aliases_by_user_ids(user_ids) when is_list(user_ids) do
    case optional_module(:email, @email_alias_module) do
      nil ->
        %{}

      alias_module ->
        from(a in alias_module,
          where: a.user_id in ^user_ids,
          order_by: [desc: a.inserted_at]
        )
        |> Elektrine.Repo.all()
        |> Enum.group_by(& &1.user_id)
    end
  end

  def admin_user_alias(alias_id, user_id) do
    call_optional(:email, @email_module, :get_alias, [alias_id, user_id], nil)
  end

  def admin_delete_user_alias(alias_record) do
    call_optional(:email, @email_module, :delete_alias, [alias_record], {:error, :unavailable})
  end

  def admin_search_email_mailboxes(query, opts \\ []) do
    search_optional_records(@email_mailbox_module, query, [:email], opts)
  end

  def admin_search_email_aliases(query, opts \\ []) do
    search_optional_records(@email_alias_module, query, [:alias_email, :target_email], opts)
  end

  def admin_unsubscribe_page(page, per_page) do
    default = %{
      unsubscribes: [],
      stats: %{total: 0, last_7_days: 0},
      list_counts: [],
      total_count: 0,
      total_pages: 1
    }

    case optional_module(:email, @email_unsubscribe_module) do
      nil ->
        default

      unsubscribe_module ->
        offset = max(page - 1, 0) * per_page

        unsubscribes =
          from(u in unsubscribe_module,
            order_by: [desc: u.unsubscribed_at],
            limit: ^per_page,
            offset: ^offset
          )
          |> Elektrine.Repo.all()
          |> Enum.map(fn unsubscribe ->
            Map.put(unsubscribe, :list_name, email_list_name(unsubscribe.list_id))
          end)

        total_count = Elektrine.Repo.aggregate(unsubscribe_module, :count, :id)

        list_counts =
          from(u in unsubscribe_module,
            group_by: u.list_id,
            select: {u.list_id, count(u.id)}
          )
          |> Elektrine.Repo.all()
          |> Enum.map(fn {list_id, count} ->
            %{
              list_id: list_id || "general",
              list_name: email_list_name(list_id),
              count: count
            }
          end)
          |> Enum.sort_by(& &1.count, :desc)

        %{
          unsubscribes: unsubscribes,
          stats:
            call_optional(
              :email,
              @email_unsubscribes_module,
              :stats,
              [],
              %{total: 0, last_7_days: 0}
            ),
          list_counts: list_counts,
          total_count: total_count,
          total_pages: max(ceil(total_count / per_page), 1)
        }
    end
  end

  def email_list_name(list_id, default \\ "elektrine-general") do
    normalized_list_id = list_id || default

    call_optional(
      :email,
      @email_list_types_module,
      :get_name,
      [normalized_list_id],
      normalized_list_id
    )
  end

  def format_fingerprint(fingerprint) do
    case optional_module(:email, @email_user_settings_module) do
      nil -> default_format_fingerprint(fingerprint)
      module -> module.format_fingerprint(fingerprint)
    end
  end

  def wkd_hash(username) do
    case optional_module(:email, @email_user_settings_module) do
      nil -> ""
      module -> module.wkd_hash(username)
    end
  end

  def private_mailbox_configured?(mailbox) do
    call_optional(:email, @email_mailbox_module, :private_storage_configured?, [mailbox], false)
  end

  def private_mailbox_unlock_mode(mailbox) do
    call_optional(
      :email,
      @email_mailbox_module,
      :private_storage_unlock_mode,
      [mailbox],
      "account_password"
    )
  end

  def storage_email_attachments(user_id) do
    call_optional(:email, @email_storage_module, :list_attachments, [user_id], [])
  end

  def delete_storage_email_attachment(user_id, message_id, attachment_id) do
    call_optional(
      :email,
      @email_storage_module,
      :delete_attachment,
      [user_id, message_id, attachment_id],
      {:error, :email_unavailable}
    )
  end

  def calendar_sidebar(assigns) do
    call_optional(:email, @email_helpers_module, :sidebar, [assigns], nil)
  end

  def email_message_count do
    case optional_module(:email, @email_message_module) do
      nil -> 0
      module -> Elektrine.Repo.aggregate(module, :count, :id)
    end
  end

  def overview_email_dashboard(user_id) do
    mailbox = call_optional(:email, @email_module, :get_user_mailbox, [user_id], nil)

    if mailbox do
      %{
        inbox_messages:
          call_optional(:email, @email_module, :list_inbox_messages, [mailbox.id, 5, 0], []),
        inbox_unread_count:
          call_optional(:email, @email_module, :unread_inbox_count, [mailbox.id], 0),
        reply_later_count:
          call_optional(:email, @email_module, :unread_reply_later_count, [mailbox.id], 0)
      }
    else
      %{inbox_messages: [], inbox_unread_count: 0, reply_later_count: 0}
    end
  end

  def overview_recent_posts(user_id, opts \\ []) do
    call_optional(:social, @social_module, :get_user_timeline_posts, [user_id, opts], [])
  end

  def social_link_preview_metadata(url) do
    call_optional(
      :social,
      @social_link_preview_fetcher_module,
      :fetch_preview_metadata,
      [url],
      %{status: "unavailable"}
    )
  end

  def social_time_ago(datetime) do
    call_optional(
      :social,
      @social_module,
      :time_ago_in_words,
      [datetime],
      default_time_ago(datetime)
    )
  end

  def social_poll_open?(poll) do
    call_optional(:social, @social_poll_module, :open?, [poll], false)
  end

  def social_poll_closed?(poll) do
    call_optional(:social, @social_poll_module, :closed?, [poll], true)
  end

  def social_user_poll_votes(poll_id, user_id) do
    call_optional(:social, @social_module, :get_user_poll_votes, [poll_id, user_id], [])
  end

  def social_user_liked_ids(user_id, message_ids) do
    social_message_ids(@social_post_like_module, user_id, message_ids)
  end

  def social_user_boosted_ids(user_id, message_ids) do
    social_message_ids(@social_post_boost_module, user_id, message_ids)
  end

  def social_user_saved_ids(user_id, message_ids) do
    social_message_ids(@social_saved_item_module, user_id, message_ids)
  end

  def profile_timeline_posts(user_id, opts \\ []) do
    call_optional(:social, @social_module, :get_user_timeline_posts, [user_id, opts], [])
  end

  def profile_pinned_posts(user_id, opts \\ []) do
    call_optional(:social, @social_module, :get_pinned_posts, [user_id, opts], [])
  end

  def overview_public_timeline(opts \\ []) do
    call_optional(:social, @social_module, :get_public_timeline, [opts], [])
  end

  def overview_for_you_feed(user_id, opts \\ []) do
    call_optional(:social, @social_recommendations_module, :get_for_you_feed, [user_id, opts], [])
  end

  def social_direct_replies_for_posts(post_ids, opts \\ []) do
    call_optional(:social, @social_module, :get_direct_replies_for_posts, [post_ids, opts], %{})
  end

  def overview_record_view_with_dwell(user_id, post_id, attrs) do
    call_optional(
      :social,
      @social_recommendations_module,
      :record_view_with_dwell,
      [user_id, post_id, attrs],
      :ok
    )
  end

  def overview_record_dismissal(user_id, post_id, type, dwell_time_ms) do
    call_optional(
      :social,
      @social_recommendations_module,
      :record_dismissal,
      [user_id, post_id, type, dwell_time_ms],
      :ok
    )
  end

  def social_like_post(user_id, message_id) do
    call_optional(
      :social,
      @social_module,
      :like_post,
      [user_id, message_id],
      {:error, :unavailable}
    )
  end

  def social_unlike_post(user_id, message_id) do
    call_optional(
      :social,
      @social_module,
      :unlike_post,
      [user_id, message_id],
      {:error, :unavailable}
    )
  end

  def social_boost_post(user_id, message_id) do
    call_optional(
      :social,
      @social_module,
      :boost_post,
      [user_id, message_id],
      {:error, :unavailable}
    )
  end

  def social_unboost_post(user_id, message_id) do
    call_optional(
      :social,
      @social_module,
      :unboost_post,
      [user_id, message_id],
      {:error, :unavailable}
    )
  end

  def social_save_post(user_id, message_id) do
    call_optional(
      :social,
      @social_module,
      :save_post,
      [user_id, message_id],
      {:error, :unavailable}
    )
  end

  def social_unsave_post(user_id, message_id) do
    call_optional(
      :social,
      @social_module,
      :unsave_post,
      [user_id, message_id],
      {:error, :unavailable}
    )
  end

  def social_create_quote_post(user_id, message_id, content) do
    call_optional(
      :social,
      @social_module,
      :create_quote_post,
      [user_id, message_id, content],
      {:error, :unavailable}
    )
  end

  def social_follow_user(follower_id, followed_id) do
    call_optional(
      :social,
      @social_module,
      :follow_user,
      [follower_id, followed_id],
      {:error, :unavailable}
    )
  end

  def social_unfollow_user(follower_id, followed_id) do
    call_optional(
      :social,
      @social_module,
      :unfollow_user,
      [follower_id, followed_id],
      {:error, :unavailable}
    )
  end

  def vpn_user_configs(user_id) do
    call_optional(:vpn, @vpn_module, :list_user_configs, [user_id], [])
  end

  def vpn_user_config_count(user_id) do
    user_id
    |> vpn_user_configs()
    |> length()
  end

  def vault_create_entry(user_id, params) do
    call_optional(
      :vault,
      @password_manager_module,
      :create_entry,
      [user_id, params],
      {:error, :unavailable}
    )
  end

  def vault_setup(user_id, params) do
    call_optional(
      :vault,
      @password_manager_module,
      :setup_vault,
      [user_id, params],
      {:error, :unavailable}
    )
  end

  def vault_delete_entry(user_id, entry_id) do
    call_optional(
      :vault,
      @password_manager_module,
      :delete_entry,
      [user_id, entry_id],
      {:error, :unavailable}
    )
  end

  def vault_delete_vault(user_id) do
    call_optional(
      :vault,
      @password_manager_module,
      :delete_vault,
      [user_id],
      {:error, :unavailable}
    )
  end

  def vault_list_entries(user_id) do
    call_optional(
      :vault,
      @password_manager_module,
      :list_entries,
      [user_id, [include_secrets: true]],
      []
    )
  end

  def vault_settings(user_id) do
    call_optional(:vault, @password_manager_module, :get_vault_settings, [user_id], nil)
  end

  def vault_entry_changeset(user_id, attrs) do
    case optional_module(:vault, @vault_entry_module) do
      nil ->
        nil

      module ->
        module
        |> struct()
        |> module.form_changeset(Map.put(attrs, "user_id", user_id))
    end
  end

  defp available?(module_id, module) do
    Modules.compiled?(module_id) and Modules.enabled?(module_id) and Code.ensure_loaded?(module)
  end

  defp optional_module(module_id, module) do
    if available?(module_id, module) do
      module
    end
  end

  defp call_optional(module_id, module, function, args, fallback) do
    case optional_module(module_id, module) do
      nil ->
        fallback

      loaded_module ->
        if function_exported?(loaded_module, function, length(args)) do
          apply(loaded_module, function, args)
        else
          fallback
        end
    end
  end

  defp aggregate_optional(module) do
    case optional_module(:email, module) do
      nil -> 0
      schema_module -> Elektrine.Repo.aggregate(schema_module, :count, :id)
    end
  end

  defp social_message_ids(module, user_id, message_ids) do
    if Enum.empty?(message_ids) do
      []
    else
      case optional_module(:social, module) do
        nil ->
          []

        schema_module ->
          from(record in schema_module,
            where: record.user_id == ^user_id and record.message_id in ^message_ids,
            select: record.message_id
          )
          |> Elektrine.Repo.all()
      end
    end
  end

  defp search_optional_records(module, query, fields, opts) do
    match = Keyword.get(opts, :match, :fuzzy)
    limit = Keyword.get(opts, :limit, nil)
    search_term = "%#{query}%"

    case optional_module(:email, module) do
      nil ->
        []

      schema_module ->
        filter =
          Enum.reduce(fields, dynamic(false), fn field_name, acc ->
            case match do
              :exact ->
                dynamic([record], ^acc or field(record, ^field_name) == ^query)

              _ ->
                dynamic([record], ^acc or ilike(field(record, ^field_name), ^search_term))
            end
          end)

        query =
          from(record in schema_module,
            where: ^filter,
            preload: [:user],
            order_by: [desc: record.inserted_at]
          )

        query =
          if is_integer(limit) do
            from(record in query, limit: ^limit)
          else
            query
          end

        Elektrine.Repo.all(query)
    end
  end

  defp assign_defaults(socket, values) do
    Enum.reduce(values, socket, fn {key, value}, acc ->
      Phoenix.Component.assign(acc, key, value)
    end)
  end

  defp user_settings_email_defaults do
    [
      loading_email: true,
      mailboxes: [],
      primary_mailbox: nil,
      aliases: [],
      user_emails: [],
      lists: [],
      lists_by_type: %{},
      unsubscribe_status: %{},
      private_mailbox_configured: false,
      private_mailbox_enabled: false,
      private_mailbox_public_key: nil,
      private_mailbox_wrapped_private_key: nil,
      private_mailbox_verifier: nil,
      private_mailbox_unlock_mode: "account_password"
    ]
  end

  defp default_format_fingerprint(nil), do: ""

  defp default_format_fingerprint(fingerprint) when is_binary(fingerprint) do
    fingerprint
    |> String.replace(~r/\s+/, "")
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  defp default_format_fingerprint(_), do: ""

  defp default_time_ago(%DateTime{} = datetime) do
    datetime
    |> DateTime.diff(DateTime.utc_now(), :second)
    |> Kernel.*(-1)
    |> format_relative_seconds()
  end

  defp default_time_ago(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> default_time_ago()
  end

  defp default_time_ago(_datetime), do: "just now"

  defp format_relative_seconds(seconds) when seconds < 60, do: "just now"
  defp format_relative_seconds(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m ago"
  defp format_relative_seconds(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)}h ago"
  defp format_relative_seconds(seconds) when seconds < 604_800, do: "#{div(seconds, 86_400)}d ago"
  defp format_relative_seconds(seconds), do: "#{div(seconds, 604_800)}w ago"
end
