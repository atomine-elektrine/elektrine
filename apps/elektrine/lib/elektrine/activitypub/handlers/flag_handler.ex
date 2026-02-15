defmodule Elektrine.ActivityPub.Handlers.FlagHandler do
  @moduledoc """
  Handles Flag (report) ActivityPub activities.

  Flag activities are used to report users or content to instance administrators.
  When we receive a Flag, we create a local report for admin review.

  ## ActivityPub Flag format

      {
        "@context": "https://www.w3.org/ns/activitystreams",
        "type": "Flag",
        "actor": "https://remote.server/users/reporter",
        "object": [
          "https://our.server/users/reported_user",
          "https://our.server/posts/123"
        ],
        "content": "This user is posting spam"
      }
  """

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.Reports
  alias Elektrine.Accounts

  @doc """
  Handles an incoming Flag (report) activity.
  Creates a local report for admin review.
  """
  def handle(%{"object" => objects, "content" => content} = _activity, actor_uri, _target_user) do
    handle_report(objects, content, actor_uri)
  end

  def handle(%{"object" => objects} = _activity, actor_uri, _target_user) do
    handle_report(objects, nil, actor_uri)
  end

  defp handle_report(objects, content, reporter_actor_uri) do
    objects = List.wrap(objects)

    # Separate user URIs from content URIs
    {user_uris, content_uris} = categorize_objects(objects)

    # Get or create the remote reporter actor
    reporter_actor =
      case ActivityPub.get_or_fetch_actor(reporter_actor_uri) do
        {:ok, actor} -> actor
        _ -> nil
      end

    # Find local users being reported
    reported_users = find_local_users(user_uris)

    # Find local messages being reported
    reported_messages = find_local_messages(content_uris)

    cond do
      # Report against a local user
      reported_users != [] ->
        Enum.each(reported_users, fn user ->
          create_federated_report(
            user,
            reported_messages,
            content,
            reporter_actor,
            reporter_actor_uri
          )
        end)

        {:ok, :report_received}

      # Report against local content only (no user specified)
      reported_messages != [] ->
        # Get the author of the first reported message
        first_message = hd(reported_messages)

        if first_message.sender_id do
          user = Accounts.get_user!(first_message.sender_id)

          if user do
            create_federated_report(
              user,
              reported_messages,
              content,
              reporter_actor,
              reporter_actor_uri
            )
          end
        end

        {:ok, :report_received}

      true ->
        Logger.debug("Flag activity targets no local users or content, ignoring")
        {:ok, :ignored}
    end
  end

  defp categorize_objects(objects) do
    Enum.reduce(objects, {[], []}, fn object_uri, {users, content} ->
      uri = normalize_uri(object_uri)

      if is_user_uri?(uri), do: {[uri | users], content}, else: {users, [uri | content]}
    end)
  end

  defp normalize_uri(uri) when is_binary(uri), do: uri
  defp normalize_uri(%{"id" => id}), do: id
  defp normalize_uri(_), do: nil

  defp is_user_uri?(nil), do: false

  defp is_user_uri?(uri) do
    base_url = ActivityPub.instance_url()
    String.starts_with?(uri, "#{base_url}/users/")
  end

  defp find_local_users(uris) do
    base_url = ActivityPub.instance_url()

    uris
    |> Enum.filter(& &1)
    |> Enum.map(fn uri ->
      if String.starts_with?(uri, "#{base_url}/users/") do
        username = String.replace_prefix(uri, "#{base_url}/users/", "")
        Accounts.get_user_by_username(username)
      end
    end)
    |> Enum.filter(& &1)
  end

  defp find_local_messages(uris) do
    base_url = ActivityPub.instance_url()

    uris
    |> Enum.filter(& &1)
    |> Enum.flat_map(fn uri ->
      cond do
        # Format: /posts/{id}
        String.starts_with?(uri, "#{base_url}/posts/") ->
          id_str = String.replace_prefix(uri, "#{base_url}/posts/", "")
          get_message_by_id_string(id_str)

        # Format: /users/{username}/statuses/{id}
        String.match?(uri, ~r{#{base_url}/users/[^/]+/statuses/}) ->
          id_str = uri |> String.split("/statuses/") |> List.last()
          get_message_by_id_string(id_str)

        # Check by activitypub_id
        true ->
          case Elektrine.Messaging.get_message_by_activitypub_id(uri) do
            nil -> []
            msg -> [msg]
          end
      end
    end)
  end

  # Safely parse ID string and fetch message
  defp get_message_by_id_string(id_str) do
    case Integer.parse(id_str) do
      {id, ""} ->
        case Elektrine.Messaging.get_message(id) do
          nil -> []
          msg -> [msg]
        end

      _ ->
        # Invalid ID format, skip
        []
    end
  end

  defp create_federated_report(
         reported_user,
         reported_messages,
         content,
         reporter_actor,
         reporter_uri
       ) do
    # Build metadata about the reporter
    reporter_info =
      if reporter_actor do
        %{
          "remote_reporter" => %{
            "uri" => reporter_actor.uri,
            "username" => reporter_actor.username,
            "domain" => reporter_actor.domain,
            "display_name" => reporter_actor.display_name
          }
        }
      else
        %{
          "remote_reporter" => %{
            "uri" => reporter_uri
          }
        }
      end

    # Add reported content URIs to metadata
    content_info =
      if reported_messages != [] do
        Map.put(reporter_info, "reported_content_ids", Enum.map(reported_messages, & &1.id))
      else
        reporter_info
      end

    # Create the report
    # Use a system reporter ID for federated reports (or first admin)
    system_reporter_id = get_system_reporter_id()

    report_attrs = %{
      reporter_id: system_reporter_id,
      reportable_type: "user",
      reportable_id: reported_user.id,
      reason: "other",
      description: build_report_description(content, reporter_actor, reporter_uri),
      status: "pending",
      priority: "normal",
      metadata: content_info
    }

    case Reports.create_report(report_attrs) do
      {:ok, report} ->
        Logger.info(
          "Created federated report ##{report.id} against user #{reported_user.username} " <>
            "from #{reporter_uri}"
        )

        # Notify admins about the new report
        notify_admins_of_federated_report(report, reported_user, reporter_actor)

        {:ok, report}

      {:error, reason} ->
        Logger.error("Failed to create federated report: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_report_description(content, reporter_actor, reporter_uri) do
    reporter_name =
      if reporter_actor do
        "@#{reporter_actor.username}@#{reporter_actor.domain}"
      else
        reporter_uri
      end

    base = "[Federated Report from #{reporter_name}]"

    if content && content != "" do
      "#{base}\n\n#{content}"
    else
      "#{base}\n\nNo additional details provided."
    end
  end

  defp get_system_reporter_id do
    # Get the first admin user to use as the reporter for federated reports
    import Ecto.Query

    case Elektrine.Repo.one(
           from(u in Elektrine.Accounts.User,
             where: u.is_admin == true,
             limit: 1,
             select: u.id
           )
         ) do
      nil ->
        # Fallback: get any user (shouldn't happen in production)
        Elektrine.Repo.one(
          from(u in Elektrine.Accounts.User,
            limit: 1,
            select: u.id
          )
        )

      admin_id ->
        admin_id
    end
  end

  defp notify_admins_of_federated_report(report, reported_user, reporter_actor) do
    # Create notifications for all admins
    import Ecto.Query

    admin_ids =
      Elektrine.Repo.all(
        from(u in Elektrine.Accounts.User,
          where: u.is_admin == true,
          select: u.id
        )
      )

    reporter_name =
      if reporter_actor do
        "@#{reporter_actor.username}@#{reporter_actor.domain}"
      else
        "a remote user"
      end

    Enum.each(admin_ids, fn admin_id ->
      Elektrine.Notifications.create_notification(%{
        user_id: admin_id,
        type: "system",
        title: "New Federated Report",
        body: "#{reporter_name} reported @#{reported_user.username}",
        source_type: "report",
        source_id: report.id,
        priority: "high"
      })
    end)
  end
end
