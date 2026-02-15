defmodule ElektrineWeb.NodeinfoController do
  use ElektrineWeb, :controller

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.MRF
  alias Elektrine.Accounts
  alias Elektrine.Messaging
  alias Elektrine.System, as: SystemSettings

  @doc """
  Returns the well-known nodeinfo links.
  GET /.well-known/nodeinfo
  """
  def well_known(conn, _params) do
    base_url = ActivityPub.instance_url()

    data = %{
      links: [
        %{
          rel: "http://nodeinfo.diaspora.software/ns/schema/2.0",
          href: "#{base_url}/nodeinfo/2.0"
        },
        %{
          rel: "http://nodeinfo.diaspora.software/ns/schema/2.1",
          href: "#{base_url}/nodeinfo/2.1"
        }
      ]
    }

    conn
    |> put_resp_content_type("application/json")
    |> json(data)
  end

  @doc """
  Returns nodeinfo 2.0 data.
  GET /nodeinfo/2.0
  """
  def nodeinfo_2_0(conn, _params) do
    render_nodeinfo(conn, "2.0")
  end

  @doc """
  Returns nodeinfo 2.1 data.
  GET /nodeinfo/2.1
  """
  def nodeinfo_2_1(conn, _params) do
    render_nodeinfo(conn, "2.1")
  end

  defp render_nodeinfo(conn, version) do
    # Get stats (cached for performance)
    stats = get_instance_stats()

    base_data = %{
      version: version,
      software: software_info(version),
      protocols: ["activitypub"],
      usage: %{
        users: %{
          total: stats.user_count,
          activeMonth: stats.active_month,
          activeHalfyear: stats.active_halfyear
        },
        localPosts: stats.post_count
      },
      openRegistrations: open_registrations?(),
      metadata: build_metadata()
    }

    conn
    |> put_resp_content_type(
      "application/json; profile=\"http://nodeinfo.diaspora.software/ns/schema/#{version}#\""
    )
    |> json(base_data)
  end

  defp software_info("2.1") do
    %{
      name: software_name(),
      version: Application.spec(:elektrine, :vsn) |> to_string(),
      homepage: "https://z.org"
    }
  end

  defp software_info(_version) do
    %{
      name: software_name(),
      version: Application.spec(:elektrine, :vsn) |> to_string()
    }
  end

  # Software name for nodeinfo
  defp software_name do
    Application.get_env(:elektrine, :nodeinfo_software_name, "z")
  end

  defp build_metadata do
    base_metadata = %{
      nodeName: "Z",
      nodeDescription: "A federated social platform",
      features: build_features(),
      postFormats: [
        "text/plain",
        "text/html"
      ]
    }

    # Add MRF transparency if enabled
    if mrf_transparency_enabled?() do
      Map.put(base_metadata, :federation, build_federation_info())
    else
      base_metadata
    end
  end

  defp open_registrations? do
    # If invite codes are enabled, registration is restricted/invite-only.
    not SystemSettings.invite_codes_enabled?()
  end

  defp build_features do
    base_features = [
      "polls",
      "emoji_reactions",
      "quote_posts",
      "media_proxy",
      "hashtag_following"
    ]

    # Add MRF-related features if enabled
    if Application.get_env(:elektrine, :mrf, [])[:policies] do
      base_features ++ ["mrf"]
    else
      base_features
    end
  end

  defp mrf_transparency_enabled? do
    Application.get_env(:elektrine, :mrf, [])[:transparency] ||
      Application.get_env(:elektrine, :mrf_transparency, true)
  end

  defp build_federation_info do
    # Use MRF.describe() to gather info from all active policies
    {:ok, mrf_data} = MRF.describe()

    # Get quarantined instances (instances with federated_timeline_removal)
    quarantined = get_quarantined_instances()

    base_federation = %{
      enabled: true,
      mrf_policies: mrf_data[:mrf_policies] || [],
      quarantined_instances: Enum.map(quarantined, fn {domain, _reason} -> domain end),
      quarantined_instances_info: %{
        "quarantined_instances" =>
          quarantined
          |> Enum.map(fn {domain, reason} -> {domain, %{"reason" => reason}} end)
          |> Map.new()
      }
    }

    # If transparency is enabled, include MRF policy details
    if mrf_data[:transparency] do
      base_federation
      |> maybe_add_mrf_simple(mrf_data[:mrf_simple])
      |> maybe_add_mrf_keyword(mrf_data[:mrf_keyword])
      |> maybe_add_mrf_hellthread(mrf_data[:mrf_hellthread])
    else
      base_federation
    end
  end

  defp maybe_add_mrf_simple(federation, nil), do: federation

  defp maybe_add_mrf_simple(federation, mrf_simple) do
    # Convert policy fields to the expected format
    formatted =
      mrf_simple
      |> Enum.map(fn {key, domains} ->
        # Map internal field names to external format
        external_key =
          case key do
            :blocked -> :reject
            :silenced -> :silence
            other -> other
          end

        {external_key, domains}
      end)
      |> Map.new()

    Map.put(federation, :mrf_simple, formatted)
  end

  defp maybe_add_mrf_keyword(federation, nil), do: federation

  defp maybe_add_mrf_keyword(federation, mrf_keyword) do
    Map.put(federation, :mrf_keyword, mrf_keyword)
  end

  defp maybe_add_mrf_hellthread(federation, nil), do: federation

  defp maybe_add_mrf_hellthread(federation, mrf_hellthread) do
    Map.put(federation, :mrf_hellthread, mrf_hellthread)
  end

  defp get_quarantined_instances do
    import Ecto.Query

    Elektrine.Repo.all(
      from(i in Elektrine.ActivityPub.Instance,
        where: i.federated_timeline_removal == true,
        select: {i.domain, i.notes}
      )
    )
    |> Enum.map(fn {domain, notes} ->
      {domain, notes || "No reason provided"}
    end)
  end

  defp get_instance_stats do
    import Ecto.Query

    user_count =
      Elektrine.Repo.aggregate(
        from(u in Accounts.User),
        :count,
        :id
      ) || 0

    post_count =
      Elektrine.Repo.aggregate(
        from(m in Messaging.Message,
          where: is_nil(m.deleted_at) and m.federated == false
        ),
        :count,
        :id
      ) || 0

    # Active users in last month
    month_ago = DateTime.utc_now() |> DateTime.add(-30, :day)

    active_month =
      Elektrine.Repo.aggregate(
        from(u in Accounts.User,
          where: u.last_login_at > ^month_ago
        ),
        :count,
        :id
      ) || 0

    # Active users in last 6 months
    halfyear_ago = DateTime.utc_now() |> DateTime.add(-180, :day)

    active_halfyear =
      Elektrine.Repo.aggregate(
        from(u in Accounts.User,
          where: u.last_login_at > ^halfyear_ago
        ),
        :count,
        :id
      ) || 0

    %{
      user_count: user_count,
      post_count: post_count,
      active_month: active_month,
      active_halfyear: active_halfyear
    }
  end
end
