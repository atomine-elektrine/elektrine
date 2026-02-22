defmodule Elektrine.Accounts.MultiAccount do
  @moduledoc """
  Multi-account detection functionality.
  Detects potential multi-account users based on IP address patterns.
  Only uses registration IP to avoid false positives from legitimate network changes.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  @doc """
  Find users sharing the same registration IP address.
  Returns a list of users grouped by IP address.
  """
  def find_users_by_registration_ip(ip_address) do
    from(u in User,
      where: u.registration_ip == ^ip_address and not is_nil(u.registration_ip),
      order_by: [desc: u.inserted_at],
      select: [
        :id,
        :username,
        :registration_ip,
        :last_login_ip,
        :last_login_at,
        :login_count,
        :inserted_at,
        :banned,
        :is_admin
      ]
    )
    |> Repo.all()
  end

  @doc """
  Detect potential multi-account users based on registration IP addresses.
  Only uses registration_ip (not last_login_ip) to avoid false positives from
  legitimate users changing networks, VPN, or traveling.
  Returns a map with registration_ip_groups.
  """
  def detect_multi_accounts do
    # Find IPs with multiple registrations
    # Only use registration_ip (not last_login_ip) to avoid false positives
    # from legitimate users changing networks/VPN/traveling
    registration_groups =
      from(u in User,
        where: not is_nil(u.registration_ip),
        group_by: u.registration_ip,
        having: count(u.id) > 1,
        select: %{
          ip: u.registration_ip,
          count: count(u.id)
        }
      )
      |> Repo.all()

    # Get detailed user info for each group
    registration_ip_groups =
      Enum.map(registration_groups, fn %{ip: ip, count: count} ->
        users = find_users_by_registration_ip(ip)
        %{ip: ip, count: count, users: users}
      end)

    %{
      registration_ip_groups: registration_ip_groups
    }
  end

  @doc """
  Detect multi-accounts with pagination.
  """
  def detect_multi_accounts_paginated(page, per_page) do
    offset = (page - 1) * per_page

    # Get total count of unique registration IPs with multiple users
    total_registration_count =
      from(u in User,
        where: not is_nil(u.registration_ip),
        group_by: u.registration_ip,
        having: count(u.id) > 1,
        select: u.registration_ip
      )
      |> Repo.all()
      |> length()

    # Get paginated registration groups
    registration_groups =
      from(u in User,
        where: not is_nil(u.registration_ip),
        group_by: u.registration_ip,
        having: count(u.id) > 1,
        order_by: [desc: count(u.id), asc: u.registration_ip],
        limit: ^per_page,
        offset: ^offset,
        select: %{
          ip: u.registration_ip,
          count: count(u.id)
        }
      )
      |> Repo.all()

    # Get detailed user info for each group
    registration_ip_groups =
      Enum.map(registration_groups, fn %{ip: ip, count: count} ->
        users = find_users_by_registration_ip(ip)
        %{ip: ip, count: count, users: users}
      end)

    # For simplicity, only paginate registration groups for now
    # Login groups would need separate pagination implementation
    login_ip_groups = []

    multi_account_data = %{
      registration_ip_groups: registration_ip_groups,
      login_ip_groups: login_ip_groups
    }

    {multi_account_data, total_registration_count}
  end

  @doc """
  Search multi-account groups with pagination.
  """
  def search_multi_accounts_paginated(search_query, page, per_page) do
    offset = (page - 1) * per_page
    search_term = "%#{search_query}%"

    # Get total count for search results
    total_count =
      from(u in User,
        where: not is_nil(u.registration_ip),
        where: ilike(u.registration_ip, ^search_term) or ilike(u.username, ^search_term),
        group_by: u.registration_ip,
        having: count(u.id) > 1,
        select: u.registration_ip
      )
      |> Repo.all()
      |> length()

    # Search registration IP groups with pagination
    registration_groups =
      from(u in User,
        where: not is_nil(u.registration_ip),
        where: ilike(u.registration_ip, ^search_term) or ilike(u.username, ^search_term),
        group_by: u.registration_ip,
        having: count(u.id) > 1,
        order_by: [desc: count(u.id), asc: u.registration_ip],
        limit: ^per_page,
        offset: ^offset,
        select: %{
          ip: u.registration_ip,
          count: count(u.id)
        }
      )
      |> Repo.all()

    # Get detailed user info for each group
    registration_ip_groups =
      Enum.map(registration_groups, fn %{ip: ip, count: count} ->
        users = find_users_by_registration_ip(ip) |> filter_users_by_search(search_term)
        %{ip: ip, count: count, users: users}
      end)

    multi_account_data = %{
      registration_ip_groups: registration_ip_groups,
      login_ip_groups: []
    }

    {multi_account_data, total_count}
  end

  @doc """
  Search multi-account groups by IP address or username.
  """
  def search_multi_accounts(search_query) do
    search_term = "%#{search_query}%"

    # Search registration IP groups
    registration_groups =
      from(u in User,
        where: not is_nil(u.registration_ip),
        where: ilike(u.registration_ip, ^search_term) or ilike(u.username, ^search_term),
        group_by: u.registration_ip,
        having: count(u.id) > 1,
        select: %{
          ip: u.registration_ip,
          count: count(u.id)
        }
      )
      |> Repo.all()

    # Get detailed user info for each group
    registration_ip_groups =
      Enum.map(registration_groups, fn %{ip: ip, count: count} ->
        users = find_users_by_registration_ip(ip) |> filter_users_by_search(search_term)
        %{ip: ip, count: count, users: users}
      end)

    %{
      registration_ip_groups: registration_ip_groups
    }
  end

  @doc """
  Get user account details with IP information for admin moderation.
  Only checks registration_ip to avoid false positives from changing login IPs.
  """
  def get_user_with_ip_info!(id) do
    user = Repo.get!(User, id)

    related_by_registration =
      if user.registration_ip do
        find_users_by_registration_ip(user.registration_ip)
        |> Enum.reject(&(&1.id == user.id))
      else
        []
      end

    %{
      user: user,
      related_by_registration: related_by_registration
    }
  end

  # Helper function to filter users by search term
  defp filter_users_by_search(users, search_term) do
    Enum.filter(users, fn user ->
      String.contains?(
        String.downcase(user.username),
        String.downcase(String.trim(search_term, "%"))
      ) or
        String.contains?(
          String.downcase(user.registration_ip || ""),
          String.downcase(String.trim(search_term, "%"))
        ) or
        String.contains?(
          String.downcase(user.last_login_ip || ""),
          String.downcase(String.trim(search_term, "%"))
        )
    end)
  end
end
