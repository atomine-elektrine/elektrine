defmodule Elektrine.Privacy do
  @moduledoc """
  Centralized privacy control system for Elektrine.

  Handles all privacy checks for:
  - Direct messages
  - Audio/video calls
  - Friend requests
  - Group/channel invites
  - Mentions
  - Profile viewing

  Privacy levels:
  - "everyone" - Anyone can interact
  - "followers" - Only users who follow you
  - "following" - Only users you follow
  - "mutual" - Only mutual followers
  - "friends" - Only accepted friends
  - "nobody" - Disabled
  """

  alias Elektrine.{Accounts, Friends, Profiles}

  @doc """
  Checks if a user can send a direct message to another user.

  Returns:
  - {:ok, :allowed} - Can send DM
  - {:error, :blocked} - User is blocked
  - {:error, :privacy_restricted} - Privacy settings prevent DMs
  """
  def can_send_dm?(sender_id, recipient_id) do
    # Can't DM yourself
    if sender_id == recipient_id do
      {:error, :cannot_dm_self}
    else
      recipient = Accounts.get_user!(recipient_id)

      # Check if blocked
      if Accounts.user_blocked?(sender_id, recipient_id) or
           Accounts.user_blocked?(recipient_id, sender_id) do
        {:error, :blocked}
      else
        check_privacy_setting(sender_id, recipient, :allow_direct_messages_from)
      end
    end
  end

  @doc """
  Checks if a user can initiate a call to another user.

  Returns:
  - {:ok, :allowed} - Can call
  - {:error, :blocked} - User is blocked
  - {:error, :privacy_restricted} - Privacy settings prevent calls
  - {:error, :not_friends} - Calls limited to friends only
  """
  def can_call?(caller_id, callee_id) do
    # Can't call yourself
    if caller_id == callee_id do
      {:error, :cannot_call_self}
    else
      callee = Accounts.get_user!(callee_id)

      # Check if blocked
      if Accounts.user_blocked?(caller_id, callee_id) or
           Accounts.user_blocked?(callee_id, caller_id) do
        {:error, :blocked}
      else
        check_privacy_setting(caller_id, callee, :allow_calls_from)
      end
    end
  end

  @doc """
  Checks if a user can send a friend request to another user.

  Returns:
  - {:ok, :allowed} - Can send request
  - {:error, :blocked} - User is blocked
  - {:error, :privacy_restricted} - Privacy settings prevent requests
  - {:error, :already_friends} - Already friends
  """
  def can_send_friend_request?(requester_id, recipient_id) do
    # Can't friend yourself
    if requester_id == recipient_id do
      {:error, :cannot_friend_self}
    else
      recipient = Accounts.get_user!(recipient_id)

      # Check if blocked
      if Accounts.user_blocked?(requester_id, recipient_id) or
           Accounts.user_blocked?(recipient_id, requester_id) do
        {:error, :blocked}
      else
        # Check if already friends
        if Friends.are_friends?(requester_id, recipient_id) do
          {:error, :already_friends}
        else
          check_privacy_setting(requester_id, recipient, :allow_friend_requests_from)
        end
      end
    end
  end

  @doc """
  Checks if a user can add another user to a group/channel.

  Returns:
  - {:ok, :allowed} - Can add
  - {:error, :blocked} - User is blocked
  - {:error, :privacy_restricted} - Privacy settings prevent adds
  """
  def can_add_to_group?(adder_id, user_to_add_id) do
    # Can always add yourself
    if adder_id == user_to_add_id do
      {:ok, :allowed}
    else
      user_to_add = Accounts.get_user!(user_to_add_id)

      # Check if blocked
      if Accounts.user_blocked?(adder_id, user_to_add_id) or
           Accounts.user_blocked?(user_to_add_id, adder_id) do
        {:error, :blocked}
      else
        check_privacy_setting(adder_id, user_to_add, :allow_group_adds_from)
      end
    end
  end

  @doc """
  Checks if a user can mention another user.

  Returns:
  - {:ok, :allowed} - Can mention
  - {:error, :blocked} - User is blocked
  - {:error, :privacy_restricted} - Privacy settings prevent mentions
  """
  def can_mention?(mentioner_id, mentioned_id) do
    # Can always mention yourself
    if mentioner_id == mentioned_id do
      {:ok, :allowed}
    else
      mentioned = Accounts.get_user!(mentioned_id)

      # Check if blocked
      if Accounts.user_blocked?(mentioner_id, mentioned_id) or
           Accounts.user_blocked?(mentioned_id, mentioner_id) do
        {:error, :blocked}
      else
        check_privacy_setting(mentioner_id, mentioned, :allow_mentions_from)
      end
    end
  end

  @doc """
  Checks if a user can view another user's profile.

  Returns:
  - {:ok, :allowed} - Can view
  - {:error, :blocked} - User is blocked
  - {:error, :privacy_restricted} - Profile is private
  """
  def can_view_profile?(viewer_id, profile_owner_id) do
    # Can always view your own profile
    if viewer_id == profile_owner_id do
      {:ok, :allowed}
    else
      owner = Accounts.get_user!(profile_owner_id)

      # Check if blocked
      if Accounts.user_blocked?(viewer_id, profile_owner_id) or
           Accounts.user_blocked?(profile_owner_id, viewer_id) do
        {:error, :blocked}
      else
        case owner.profile_visibility do
          "public" ->
            {:ok, :allowed}

          "followers" ->
            if Profiles.following?(profile_owner_id, viewer_id) do
              {:ok, :allowed}
            else
              {:error, :privacy_restricted}
            end

          "private" ->
            {:error, :privacy_restricted}

          _ ->
            {:ok, :allowed}
        end
      end
    end
  end

  # Private helper function to check privacy settings
  defp check_privacy_setting(actor_id, target_user, setting_field) do
    privacy_level = Map.get(target_user, setting_field)

    case privacy_level do
      "everyone" ->
        {:ok, :allowed}

      "friends" ->
        if Friends.are_friends?(actor_id, target_user.id) do
          {:ok, :allowed}
        else
          {:error, :privacy_restricted}
        end

      "followers" ->
        if Profiles.following?(target_user.id, actor_id) do
          {:ok, :allowed}
        else
          {:error, :privacy_restricted}
        end

      "following" ->
        if Profiles.following?(actor_id, target_user.id) do
          {:ok, :allowed}
        else
          {:error, :privacy_restricted}
        end

      "mutual" ->
        if Profiles.following?(actor_id, target_user.id) and
             Profiles.following?(target_user.id, actor_id) do
          {:ok, :allowed}
        else
          {:error, :privacy_restricted}
        end

      "nobody" ->
        {:error, :privacy_restricted}

      _ ->
        # Default to everyone if invalid setting
        {:ok, :allowed}
    end
  end

  @doc """
  Gets privacy error message for display to users.
  """
  def privacy_error_message(error_type) do
    case error_type do
      :blocked ->
        "You have blocked this user or they have blocked you"

      :privacy_restricted ->
        "This user's privacy settings prevent this action"

      :privacy_settings_changed ->
        "This user has changed their privacy settings and is no longer accepting friend requests"

      :not_friends ->
        "You must be friends with this user"

      :cannot_dm_self ->
        "You cannot send messages to yourself"

      :cannot_call_self ->
        "You cannot call yourself"

      :cannot_friend_self ->
        "You cannot send a friend request to yourself"

      :already_friends ->
        "You are already friends with this user"

      _ ->
        "Action not allowed"
    end
  end

  @doc """
  Returns the available privacy options for each setting.
  """
  def privacy_options(:allow_calls_from), do: ["everyone", "friends", "nobody"]

  def privacy_options(:allow_direct_messages_from),
    do: ["everyone", "following", "followers", "mutual", "friends", "nobody"]

  def privacy_options(:allow_group_adds_from),
    do: ["everyone", "following", "followers", "mutual", "friends", "nobody"]

  def privacy_options(:allow_mentions_from),
    do: ["everyone", "following", "followers", "mutual", "friends", "nobody"]

  def privacy_options(:allow_friend_requests_from), do: ["everyone", "followers", "nobody"]
  def privacy_options(:profile_visibility), do: ["public", "followers", "private"]
  def privacy_options(:default_post_visibility), do: ["public", "followers", "friends", "private"]

  @doc """
  Returns human-readable label for privacy option.
  """
  def privacy_label("everyone"), do: "Everyone"
  def privacy_label("friends"), do: "Friends Only"
  def privacy_label("followers"), do: "Followers Only"
  def privacy_label("following"), do: "People I Follow"
  def privacy_label("mutual"), do: "Mutual Followers"
  def privacy_label("nobody"), do: "Nobody"
  def privacy_label("public"), do: "Public"
  def privacy_label("private"), do: "Private"
  def privacy_label(_), do: "Unknown"
end
