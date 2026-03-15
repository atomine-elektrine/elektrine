defmodule Elektrine.Reputation do
  @moduledoc """
  Public reputation graph data built from trust, invite lineage, and local follow edges.
  """

  import Ecto.Query, warn: false

  alias Elektrine.{Accounts, Profiles, Repo, Uploads}
  alias Elektrine.Accounts.{InviteCode, InviteCodeUse, TrustLevel, User}

  @sample_limit 4

  @palette %{
    0 => %{accent: "#94a3b8", surface: "#f8fafc", glow: "rgba(148, 163, 184, 0.28)"},
    1 => %{accent: "#0ea5e9", surface: "#f0f9ff", glow: "rgba(14, 165, 233, 0.28)"},
    2 => %{accent: "#10b981", surface: "#ecfdf5", glow: "rgba(16, 185, 129, 0.28)"},
    3 => %{accent: "#f59e0b", surface: "#fffbeb", glow: "rgba(245, 158, 11, 0.28)"},
    4 => %{accent: "#ef4444", surface: "#fef2f2", glow: "rgba(239, 68, 68, 0.28)"}
  }

  def search_public_users(query, limit \\ 8) do
    query = query |> to_string() |> String.trim()

    if String.length(query) < 2 do
      []
    else
      query_term =
        "%" <> String.downcase(Elektrine.TextHelpers.sanitize_search_term(query)) <> "%"

      User
      |> where([u], u.profile_visibility == "public")
      |> where(
        [u],
        fragment("LOWER(?) LIKE ?", u.username, ^query_term) or
          fragment("LOWER(?) LIKE ?", u.display_name, ^query_term) or
          fragment("LOWER(?) LIKE ?", u.handle, ^query_term)
      )
      |> order_by(
        [u],
        asc:
          fragment(
            "CASE WHEN LOWER(COALESCE(?, '')) = ? OR LOWER(?) = ? OR LOWER(?) = ? THEN 0 ELSE 1 END",
            u.handle,
            ^String.downcase(query),
            u.username,
            ^String.downcase(query),
            u.display_name,
            ^String.downcase(query)
          ),
        asc: u.username
      )
      |> limit(^limit)
      |> select([u], %{
        id: u.id,
        handle: u.handle,
        username: u.username,
        display_name: u.display_name,
        trust_level: u.trust_level,
        avatar_url: u.avatar
      })
      |> Repo.all()
      |> Enum.map(fn result ->
        Map.put(result, :avatar_url, Uploads.avatar_url(result.avatar_url))
      end)
    end
  end

  def build_public_graph(%User{} = user, viewer \\ nil) do
    trust_info = TrustLevel.get_level_info(user.trust_level)
    palette = Map.get(@palette, user.trust_level, @palette[0])
    handle = display_handle(user)
    account_age_days = account_age_days(user)
    follower_count = Profiles.get_follower_count(user.id)
    following_count = Profiles.get_following_count(user.id)
    invitee_count = invitee_count(user.id)
    inviter = inviter(user, viewer)
    invitees = invitees(user.id, viewer)
    followers = followers(user.id, viewer)
    following = following(user.id, viewer)

    subject_id = subject_id(user)

    nodes =
      [
        %{
          id: subject_id,
          kind: "subject",
          cluster: "core",
          label: "@" <> handle,
          subtitle: trust_info.name,
          href: graph_path(user),
          avatar_url: Uploads.avatar_url(user.avatar),
          avatar_label: avatar_label(user),
          weight: 1.0
        },
        %{
          id: "trust:#{user.id}",
          kind: "trust",
          cluster: "trust",
          label: "TL#{user.trust_level}",
          subtitle: trust_info.name,
          weight: 0.8
        },
        %{
          id: "age:#{user.id}",
          kind: "signal",
          cluster: "age",
          label: age_label(account_age_days),
          subtitle: "account age",
          weight: 0.64
        },
        %{
          id: "followers:#{user.id}",
          kind: "aggregate",
          cluster: "followers",
          label: Integer.to_string(follower_count),
          subtitle: "followers",
          weight: aggregate_weight(follower_count)
        },
        %{
          id: "following:#{user.id}",
          kind: "aggregate",
          cluster: "following",
          label: Integer.to_string(following_count),
          subtitle: "following",
          weight: aggregate_weight(following_count)
        },
        %{
          id: "invitees:#{user.id}",
          kind: "aggregate",
          cluster: "invite",
          label: Integer.to_string(invitee_count),
          subtitle: "invitees",
          weight: aggregate_weight(invitee_count)
        }
      ] ++
        maybe_inviter_node(inviter) ++
        Enum.map(invitees, &sample_node(&1, "invitee", "invitee", "invite accepted")) ++
        Enum.map(followers, &sample_node(&1, "follower", "followers", "follows this user")) ++
        Enum.map(following, &sample_node(&1, "following", "following", "followed by this user"))

    edges =
      [
        %{
          source: subject_id,
          target: "trust:#{user.id}",
          kind: "trust",
          label: "trust"
        },
        %{
          source: subject_id,
          target: "age:#{user.id}",
          kind: "signal",
          label: "longevity"
        },
        %{
          source: subject_id,
          target: "followers:#{user.id}",
          kind: "network",
          label: "reach"
        },
        %{
          source: subject_id,
          target: "following:#{user.id}",
          kind: "network",
          label: "outgoing"
        },
        %{
          source: subject_id,
          target: "invitees:#{user.id}",
          kind: "invite",
          label: "issued"
        }
      ] ++
        maybe_inviter_edge(inviter, user) ++
        Enum.map(invitees, fn invitee ->
          %{
            source: subject_id,
            target: sample_id("invitee", invitee.id),
            kind: "invite",
            label: "invite"
          }
        end) ++
        Enum.map(followers, fn follower ->
          %{
            source: sample_id("follower", follower.id),
            target: subject_id,
            kind: "follow",
            label: "follow"
          }
        end) ++
        Enum.map(following, fn followee ->
          %{
            source: subject_id,
            target: sample_id("following", followee.id),
            kind: "follow",
            label: "follow"
          }
        end)

    %{
      palette: palette,
      subject: %{
        id: user.id,
        handle: handle,
        display_name: user.display_name || handle,
        avatar_url: Uploads.avatar_url(user.avatar),
        trust_level: user.trust_level,
        trust_name: trust_info.name
      },
      stats: [
        %{label: "Trust", value: "TL#{user.trust_level}", note: trust_info.name},
        %{
          label: "Invitees",
          value: Integer.to_string(invitee_count),
          note: "accepted invite codes"
        },
        %{
          label: "Followers",
          value: Integer.to_string(follower_count),
          note: "public network reach"
        },
        %{label: "Age", value: age_label(account_age_days), note: "time in network"}
      ],
      highlights:
        Enum.reject(
          [
            inviter && "Invited by @#{display_handle(inviter)}",
            invitee_count > 0 && "#{invitee_count} accepted invite#{pluralize(invitee_count)}",
            follower_count > 0 && "#{follower_count} follower#{pluralize(follower_count)}",
            following_count > 0 && "#{following_count} following"
          ],
          &is_nil/1
        ),
      nodes: nodes,
      edges: edges
    }
  end

  defp inviter(%User{} = user, viewer) do
    InviteCodeUse
    |> join(:inner, [icu], invite_code in InviteCode, on: invite_code.id == icu.invite_code_id)
    |> join(:inner, [_icu, invite_code], inviter in User,
      on: inviter.id == invite_code.created_by_id
    )
    |> where([icu], icu.user_id == ^user.id)
    |> limit(1)
    |> select([_icu, _invite_code, inviter], inviter)
    |> Repo.one()
    |> maybe_visible(viewer)
  end

  defp invitees(user_id, viewer) do
    InviteCode
    |> where([invite_code], invite_code.created_by_id == ^user_id)
    |> join(:inner, [invite_code], invite_use in InviteCodeUse,
      on: invite_use.invite_code_id == invite_code.id
    )
    |> join(:inner, [_invite_code, invite_use], invitee in User,
      on: invitee.id == invite_use.user_id
    )
    |> distinct([_invite_code, _invite_use, invitee], invitee.id)
    |> order_by([_invite_code, _invite_use, invitee], desc: invitee.inserted_at)
    |> limit(12)
    |> select([_invite_code, _invite_use, invitee], invitee)
    |> Repo.all()
    |> Enum.map(&maybe_visible(&1, viewer))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@sample_limit)
  end

  defp invitee_count(user_id) do
    InviteCode
    |> where([invite_code], invite_code.created_by_id == ^user_id)
    |> join(:inner, [invite_code], invite_use in InviteCodeUse,
      on: invite_use.invite_code_id == invite_code.id
    )
    |> select([_invite_code, invite_use], count(invite_use.user_id, :distinct))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp followers(user_id, viewer) do
    Profiles.get_followers(user_id, limit: 20)
    |> Enum.filter(&(&1.type == "local" && match?(%User{}, &1.user)))
    |> Enum.map(&maybe_visible(&1.user, viewer))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@sample_limit)
  end

  defp following(user_id, viewer) do
    Profiles.get_following(user_id, limit: 20)
    |> Enum.filter(&(&1.type == "local" && match?(%User{}, &1.user)))
    |> Enum.map(&maybe_visible(&1.user, viewer))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@sample_limit)
  end

  defp maybe_visible(%User{} = user, viewer) do
    case Accounts.can_view_profile?(user, viewer) do
      {:ok, :allowed} -> user
      _ -> nil
    end
  end

  defp maybe_visible(nil, _viewer), do: nil

  defp maybe_inviter_node(nil), do: []

  defp maybe_inviter_node(%User{} = inviter) do
    [
      %{
        id: sample_id("inviter", inviter.id),
        kind: "inviter",
        cluster: "invite",
        label: "@" <> display_handle(inviter),
        subtitle: "invited this account",
        href: graph_path(inviter),
        avatar_url: Uploads.avatar_url(inviter.avatar),
        avatar_label: avatar_label(inviter),
        weight: 0.72
      }
    ]
  end

  defp maybe_inviter_edge(nil, _user), do: []

  defp maybe_inviter_edge(%User{} = inviter, %User{} = user) do
    [
      %{
        source: sample_id("inviter", inviter.id),
        target: subject_id(user),
        kind: "invite",
        label: "invited"
      }
    ]
  end

  defp sample_node(%User{} = user, kind, cluster, subtitle) do
    %{
      id: sample_id(kind, user.id),
      kind: kind,
      cluster: cluster,
      label: "@" <> display_handle(user),
      subtitle: subtitle,
      href: graph_path(user),
      avatar_url: Uploads.avatar_url(user.avatar),
      avatar_label: avatar_label(user),
      weight: 0.58
    }
  end

  defp aggregate_weight(value) when value >= 20, do: 0.78
  defp aggregate_weight(value) when value >= 5, do: 0.7
  defp aggregate_weight(_value), do: 0.62

  defp age_label(days) when days < 1, do: "today"
  defp age_label(days), do: "#{days}d"

  defp account_age_days(%User{inserted_at: %DateTime{} = inserted_at}) do
    Date.diff(Date.utc_today(), DateTime.to_date(inserted_at))
  end

  defp account_age_days(_), do: 0

  defp display_handle(%User{} = user), do: user.handle || user.username

  defp avatar_label(%User{} = user) do
    user.display_name
    |> Kernel.||(display_handle(user))
    |> String.trim()
    |> String.first()
    |> Kernel.||("?")
    |> String.upcase()
  end

  defp graph_path(%User{} = user), do: "/reputation/" <> display_handle(user)

  defp subject_id(%User{} = user), do: "subject:#{user.id}"
  defp sample_id(kind, id), do: "#{kind}:#{id}"

  defp pluralize(1), do: ""
  defp pluralize(_), do: "s"
end
