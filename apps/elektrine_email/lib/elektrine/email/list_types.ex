defmodule Elektrine.Email.ListTypes do
  @moduledoc """
  Defines email list types and their properties.

  Email lists are categorized into:
  - Transactional: Critical emails that cannot be unsubscribed from
  - Marketing: Promotional and non-essential emails that can be unsubscribed from
  - Notifications: System notifications that can be managed via preferences
  """

  @type list_type :: :transactional | :marketing | :notifications
  @type list_info :: %{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          type: list_type(),
          can_unsubscribe: boolean()
        }

  @doc """
  Returns all available email lists with their metadata.
  """
  @spec all_lists() :: [list_info()]
  def all_lists do
    [
      # Transactional emails - cannot be unsubscribed
      %{
        id: "elektrine-transactional",
        name: "Transactional",
        description: "Critical account emails (cannot unsubscribe)",
        type: :transactional,
        can_unsubscribe: false
      },
      %{
        id: "elektrine-security",
        name: "Security Alerts",
        description: "Security and authentication notifications (cannot unsubscribe)",
        type: :transactional,
        can_unsubscribe: false
      },
      %{
        id: "elektrine-account",
        name: "Account Notifications",
        description: "Important account updates (cannot unsubscribe)",
        type: :transactional,
        can_unsubscribe: false
      },
      %{
        id: "elektrine-password-reset",
        name: "Password Resets",
        description: "Password reset emails (cannot unsubscribe)",
        type: :transactional,
        can_unsubscribe: false
      },
      %{
        id: "elektrine-two-factor",
        name: "Two-Factor Authentication",
        description: "2FA codes and setup (cannot unsubscribe)",
        type: :transactional,
        can_unsubscribe: false
      },

      # Marketing emails - can be unsubscribed
      %{
        id: "elektrine-marketing",
        name: "Marketing & Promotions",
        description: "Product updates, features, and promotional content",
        type: :marketing,
        can_unsubscribe: true
      },
      %{
        id: "elektrine-newsletter",
        name: "Newsletter",
        description: "Weekly/monthly newsletter with platform updates",
        type: :marketing,
        can_unsubscribe: true
      },
      %{
        id: "elektrine-announcements",
        name: "Announcements",
        description: "Platform announcements and news",
        type: :marketing,
        can_unsubscribe: true
      },

      # Notification emails - can be managed
      %{
        id: "elektrine-social",
        name: "Social Notifications",
        description: "Follows, mentions, and social interactions",
        type: :notifications,
        can_unsubscribe: true
      },
      %{
        id: "elektrine-messages",
        name: "Message Notifications",
        description: "New message alerts",
        type: :notifications,
        can_unsubscribe: true
      },
      %{
        id: "elektrine-email-notifications",
        name: "Email Notifications",
        description: "New email alerts for your mailbox",
        type: :notifications,
        can_unsubscribe: true
      },

      # General/default
      %{
        id: "elektrine-general",
        name: "General",
        description: "General platform communications",
        type: :notifications,
        can_unsubscribe: true
      }
    ]
  end

  @doc """
  Returns lists that can be unsubscribed from.
  """
  @spec subscribable_lists() :: [list_info()]
  def subscribable_lists do
    all_lists()
    |> Enum.filter(& &1.can_unsubscribe)
  end

  @doc """
  Returns transactional email lists.
  """
  @spec transactional_lists() :: [list_info()]
  def transactional_lists do
    all_lists()
    |> Enum.filter(&(&1.type == :transactional))
  end

  @doc """
  Checks if a list ID is transactional.
  """
  @spec transactional?(String.t()) :: boolean()
  def transactional?(list_id) do
    list_id in Enum.map(transactional_lists(), & &1.id)
  end

  @doc """
  Gets list information by ID.
  """
  @spec get_list(String.t()) :: list_info() | nil
  def get_list(list_id) do
    Enum.find(all_lists(), &(&1.id == list_id))
  end

  @doc """
  Gets the display name for a list ID.
  """
  @spec get_name(String.t()) :: String.t()
  def get_name(list_id) do
    case get_list(list_id) do
      %{name: name} -> name
      nil -> list_id
    end
  end

  @doc """
  Groups lists by type.
  """
  @spec lists_by_type() :: %{list_type() => [list_info()]}
  def lists_by_type do
    all_lists()
    |> Enum.group_by(& &1.type)
  end
end
