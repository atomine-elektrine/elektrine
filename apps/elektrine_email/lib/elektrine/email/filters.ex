defmodule Elektrine.Email.Filters do
  @moduledoc """
  Context module for managing email filters/rules.
  """
  import Ecto.Query
  alias Elektrine.Email.Filter
  alias Elektrine.Repo

  require Logger

  @doc """
  Lists all filters for a user, ordered by priority.
  """
  def list_filters(user_id) do
    Filter
    |> where(user_id: ^user_id)
    |> order_by(asc: :priority, asc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Lists only enabled filters for a user, ordered by priority.
  """
  def list_enabled_filters(user_id) do
    Filter
    |> where(user_id: ^user_id, enabled: true)
    |> order_by(asc: :priority, asc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a filter by ID for a user.
  """
  def get_filter(id, user_id) do
    Filter
    |> where(id: ^id, user_id: ^user_id)
    |> Repo.one()
  end

  @doc """
  Creates a filter.
  """
  def create_filter(attrs) do
    %Filter{}
    |> Filter.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a filter.
  """
  def update_filter(%Filter{} = filter, attrs) do
    filter
    |> Filter.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a filter.
  """
  def delete_filter(%Filter{} = filter) do
    Repo.delete(filter)
  end

  @doc """
  Toggles a filter's enabled status.
  """
  def toggle_filter(%Filter{} = filter) do
    filter
    |> Filter.changeset(%{enabled: !filter.enabled})
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking filter changes.
  """
  def change_filter(%Filter{} = filter, attrs \\ %{}) do
    Filter.changeset(filter, attrs)
  end

  @doc """
  Applies all enabled filters to a message and returns the actions to take.
  Returns a map of actions accumulated from all matching filters.
  """
  def apply_filters(user_id, message) do
    filters = list_enabled_filters(user_id)

    {actions, _stopped} =
      Enum.reduce_while(filters, {%{}, false}, fn filter, {acc_actions, _stopped} ->
        if Filter.matches?(filter, message) do
          Logger.debug("Filter '#{filter.name}' matched message #{message.id}")

          # Merge actions (later filters can override earlier ones)
          new_actions = Map.merge(acc_actions, filter.actions)

          if filter.stop_processing do
            {:halt, {new_actions, true}}
          else
            {:cont, {new_actions, false}}
          end
        else
          {:cont, {acc_actions, false}}
        end
      end)

    actions
  end

  @doc """
  Executes filter actions on a message.
  Returns {:ok, updated_message} or {:error, reason}.
  """
  def execute_actions(message, actions) when map_size(actions) == 0 do
    {:ok, message}
  end

  def execute_actions(message, actions) do
    Enum.reduce_while(actions, {:ok, message}, fn {action, value}, {:ok, msg} ->
      case execute_action(msg, action, value) do
        {:ok, updated_msg} -> {:cont, {:ok, updated_msg}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_action(message, "mark_as_read", true) do
    Elektrine.Email.mark_as_read(message)
  end

  defp execute_action(message, "mark_as_unread", true) do
    Elektrine.Email.mark_as_unread(message)
  end

  defp execute_action(message, "mark_as_spam", true) do
    Elektrine.Email.mark_as_spam(message)
  end

  defp execute_action(message, "archive", true) do
    Elektrine.Email.archive_message(message)
  end

  defp execute_action(message, "delete", true) do
    Elektrine.Email.trash_message(message)
  end

  defp execute_action(message, "star", true) do
    Elektrine.Email.update_message(message, %{flagged: true})
  end

  defp execute_action(message, "unstar", true) do
    Elektrine.Email.update_message(message, %{flagged: false})
  end

  defp execute_action(message, "set_priority", priority)
       when priority in ["high", "normal", "low"] do
    Elektrine.Email.update_message(message, %{priority: priority})
  end

  defp execute_action(message, "move_to_folder", folder_id) do
    Elektrine.Email.update_message(message, %{folder_id: folder_id})
  end

  defp execute_action(message, "add_label", label_id) do
    Elektrine.Email.Labels.add_label_to_message(message.id, label_id)
    {:ok, message}
  end

  defp execute_action(message, "remove_label", label_id) do
    Elektrine.Email.Labels.remove_label_from_message(message.id, label_id)
    {:ok, message}
  end

  defp execute_action(message, "forward_to", email) do
    # Queue a forward action (don't block processing)
    Elektrine.Async.run(fn ->
      Elektrine.Email.Sender.forward_message(message, email)
    end)

    {:ok, message}
  end

  defp execute_action(message, _action, _value) do
    {:ok, message}
  end
end
