defmodule Elektrine.Email.ImapSubscriptions do
  @moduledoc """
  Context helpers for IMAP folder subscription management.
  """
  import Ecto.Query

  alias Elektrine.Email.ImapSubscription
  alias Elektrine.Repo

  def has_records?(user_id) when is_integer(user_id) do
    Repo.exists?(from s in ImapSubscription, where: s.user_id == ^user_id)
  end

  def has_records?(_), do: false

  def list_folder_names(user_id) when is_integer(user_id) do
    from(s in ImapSubscription,
      where: s.user_id == ^user_id,
      select: s.folder_name
    )
    |> Repo.all()
  end

  def list_folder_names(_), do: []

  def subscribed_folder_set(user_id, default_folders) when is_integer(user_id) do
    subscribed = list_folder_names(user_id)

    folders =
      if subscribed == [] do
        default_folders
      else
        subscribed
      end

    MapSet.new(folders)
  end

  def ensure_seeded(user_id, folder_names) when is_integer(user_id) and is_list(folder_names) do
    if has_records?(user_id) do
      :ok
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        folder_names
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.map(fn folder_name ->
          %{
            user_id: user_id,
            folder_name: folder_name,
            inserted_at: now,
            updated_at: now
          }
        end)

      if rows == [] do
        :ok
      else
        Repo.insert_all(ImapSubscription, rows,
          on_conflict: :nothing,
          conflict_target: [:user_id, :folder_name]
        )

        :ok
      end
    end
  end

  def ensure_seeded(_user_id, _folder_names), do: :ok

  def subscribe_folder(user_id, folder_name)
      when is_integer(user_id) and is_binary(folder_name) do
    %ImapSubscription{}
    |> ImapSubscription.changeset(%{
      user_id: user_id,
      folder_name: String.trim(folder_name)
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :folder_name])
  end

  def subscribe_folder(_user_id, _folder_name), do: {:error, :invalid_params}

  def unsubscribe_folder(user_id, folder_name)
      when is_integer(user_id) and is_binary(folder_name) do
    from(s in ImapSubscription,
      where: s.user_id == ^user_id and s.folder_name == ^String.trim(folder_name)
    )
    |> Repo.delete_all()

    :ok
  end

  def unsubscribe_folder(_user_id, _folder_name), do: {:error, :invalid_params}

  def remove_folder_subscription(user_id, folder_name) do
    unsubscribe_folder(user_id, folder_name)
  end

  def rename_folder_subscription(user_id, old_folder_name, new_folder_name)
      when is_integer(user_id) and is_binary(old_folder_name) and is_binary(new_folder_name) do
    old_folder_name = String.trim(old_folder_name)
    new_folder_name = String.trim(new_folder_name)

    if old_folder_name == "" or new_folder_name == "" do
      :ok
    else
      old_query =
        from(s in ImapSubscription,
          where: s.user_id == ^user_id and s.folder_name == ^old_folder_name
        )

      if Repo.exists?(old_query) do
        Repo.delete_all(old_query)
        subscribe_folder(user_id, new_folder_name)
      end

      :ok
    end
  end

  def rename_folder_subscription(_user_id, _old_folder_name, _new_folder_name), do: :ok
end
