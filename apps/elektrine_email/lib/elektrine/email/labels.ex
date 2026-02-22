defmodule Elektrine.Email.Labels do
  @moduledoc """
  Context module for managing email labels/tags.
  """
  import Ecto.Query
  alias Elektrine.Email.Label
  alias Elektrine.Repo

  @max_labels_per_user 50

  @doc """
  Lists all labels for a user.
  """
  def list_labels(user_id) do
    Label
    |> where(user_id: ^user_id)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Gets a label by ID for a user.
  """
  def get_label(id, user_id) do
    Label
    |> where(id: ^id, user_id: ^user_id)
    |> Repo.one()
  end

  @doc """
  Gets a label by name for a user.
  """
  def get_label_by_name(name, user_id) do
    Label
    |> where(user_id: ^user_id, name: ^name)
    |> Repo.one()
  end

  @doc """
  Creates a label.
  """
  def create_label(attrs) do
    user_id = Map.get(attrs, :user_id) || Map.get(attrs, "user_id")

    if count_labels(user_id) >= @max_labels_per_user do
      {:error, :limit_reached}
    else
      %Label{}
      |> Label.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Updates a label.
  """
  def update_label(%Label{} = label, attrs) do
    label
    |> Label.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a label.
  """
  def delete_label(%Label{} = label) do
    Repo.delete(label)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking label changes.
  """
  def change_label(%Label{} = label, attrs \\ %{}) do
    Label.changeset(label, attrs)
  end

  @doc """
  Counts labels for a user.
  """
  def count_labels(user_id) do
    Label
    |> where(user_id: ^user_id)
    |> select(count())
    |> Repo.one()
  end

  @doc """
  Adds a label to a message.
  """
  def add_label_to_message(message_id, label_id) do
    Repo.insert_all(
      "email_message_labels",
      [%{message_id: message_id, label_id: label_id}],
      on_conflict: :nothing
    )

    :ok
  end

  @doc """
  Removes a label from a message.
  """
  def remove_label_from_message(message_id, label_id) do
    from(ml in "email_message_labels",
      where: ml.message_id == ^message_id and ml.label_id == ^label_id
    )
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Gets all labels for a message.
  """
  def get_message_labels(message_id, user_id) do
    Label
    |> join(:inner, [l], ml in "email_message_labels", on: ml.label_id == l.id)
    |> where([l, ml], ml.message_id == ^message_id and l.user_id == ^user_id)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Lists messages with a specific label.
  """
  def list_labeled_messages(label_id, user_id, page \\ 1, per_page \\ 20) do
    label = get_label(label_id, user_id)

    if label do
      offset = (page - 1) * per_page

      message_ids =
        from(ml in "email_message_labels",
          where: ml.label_id == ^label_id,
          select: ml.message_id
        )
        |> Repo.all()

      messages =
        Elektrine.Email.Message
        |> where([m], m.id in ^message_ids)
        |> where([m], m.deleted == false)
        |> order_by(desc: :inserted_at)
        |> limit(^per_page)
        |> offset(^offset)
        |> Repo.all()

      total = length(message_ids)

      %{
        messages: messages,
        total: total,
        page: page,
        per_page: per_page,
        has_next: offset + per_page < total,
        has_prev: page > 1,
        label: label
      }
    else
      %{
        messages: [],
        total: 0,
        page: page,
        per_page: per_page,
        has_next: false,
        has_prev: false,
        label: nil
      }
    end
  end

  @doc """
  Sets labels for a message (replaces existing labels).
  """
  def set_message_labels(message_id, label_ids) do
    # Remove all existing labels
    from(ml in "email_message_labels", where: ml.message_id == ^message_id)
    |> Repo.delete_all()

    # Add new labels
    if label_ids && label_ids != [] do
      entries =
        Enum.map(label_ids, fn label_id -> %{message_id: message_id, label_id: label_id} end)

      Repo.insert_all("email_message_labels", entries, on_conflict: :nothing)
    end

    :ok
  end
end
