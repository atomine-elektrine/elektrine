defmodule Elektrine.JMAP.Thread do
  @moduledoc """
  Schema for email threads. Threads group related messages together based on
  In-Reply-To, References headers, or normalized subject matching.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Email.Message
  alias Elektrine.Repo

  schema "email_threads" do
    field :subject_hash, :string

    belongs_to :mailbox, Elektrine.Email.Mailbox
    has_many :messages, Elektrine.Email.Message

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a new thread.
  """
  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:mailbox_id, :subject_hash])
    |> validate_required([:mailbox_id, :subject_hash])
    |> unique_constraint([:mailbox_id, :subject_hash])
  end

  @doc """
  Finds or creates a thread for a message based on:
  1. In-Reply-To header (exact match)
  2. References header (any match)
  3. Normalized subject hash

  Returns {:ok, thread_id} or {:error, reason}
  """
  def assign_thread(attrs, mailbox_id) do
    in_reply_to =
      attrs
      |> Map.get(:in_reply_to, Map.get(attrs, "in_reply_to"))
      |> parse_message_id()

    references =
      attrs
      |> Map.get(:references, Map.get(attrs, "references"))
      |> parse_reference_ids()

    subject = attrs[:subject] || attrs["subject"] || ""

    # Try to find existing thread
    thread_id =
      find_thread_by_in_reply_to(in_reply_to, mailbox_id) ||
        find_thread_by_references(references, mailbox_id) ||
        find_or_create_thread_by_subject(subject, mailbox_id)

    {:ok, thread_id}
  end

  @doc """
  Normalizes a subject by removing Re:, Fwd:, [List] prefixes and hashing.
  """
  def normalize_subject(nil), do: normalize_subject("")
  def normalize_subject(""), do: :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)

  def normalize_subject(subject) do
    subject
    |> String.replace(~r/^(Re|Fwd|Fw|Aw|Sv|回复|答复|转发):\s*/iu, "")
    |> String.replace(~r/^\[.*?\]\s*/, "")
    |> String.downcase()
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Find thread by In-Reply-To header
  defp find_thread_by_in_reply_to(nil, _mailbox_id), do: nil
  defp find_thread_by_in_reply_to("", _mailbox_id), do: nil

  defp find_thread_by_in_reply_to(in_reply_to, mailbox_id) do
    normalized_message_id = parse_message_id(in_reply_to)

    case Repo.one(
           from m in Message,
             where:
               m.mailbox_id == ^mailbox_id and
                 m.message_id in ^message_id_candidates(normalized_message_id),
             select: %{id: m.id, thread_id: m.thread_id, subject: m.subject}
         ) do
      nil ->
        nil

      %{thread_id: thread_id} when is_integer(thread_id) ->
        thread_id

      %{id: parent_id, subject: parent_subject} ->
        thread_id = find_or_create_thread_by_subject(parent_subject || "", mailbox_id)
        attach_parent_to_thread(parent_id, thread_id)
        thread_id
    end
  end

  # Find thread by References header
  defp find_thread_by_references(nil, _mailbox_id), do: nil
  defp find_thread_by_references("", _mailbox_id), do: nil

  defp find_thread_by_references(references, mailbox_id) do
    message_ids = parse_reference_ids(references)

    if Enum.empty?(message_ids) do
      nil
    else
      message_id_candidates =
        message_ids
        |> Enum.flat_map(&message_id_candidates/1)
        |> Enum.uniq()

      parent_messages =
        Repo.all(
          from m in Message,
            where: m.mailbox_id == ^mailbox_id and m.message_id in ^message_id_candidates,
            select: %{id: m.id, thread_id: m.thread_id, subject: m.subject},
            order_by: [desc: m.inserted_at]
        )

      case Enum.find(parent_messages, &is_integer(&1.thread_id)) do
        %{thread_id: thread_id} ->
          thread_id

        nil ->
          case List.first(parent_messages) do
            %{id: parent_id, subject: parent_subject} ->
              thread_id = find_or_create_thread_by_subject(parent_subject || "", mailbox_id)
              attach_parent_to_thread(parent_id, thread_id)
              thread_id

            nil ->
              nil
          end
      end
    end
  end

  # Find or create thread by normalized subject
  defp find_or_create_thread_by_subject(subject, mailbox_id) do
    subject_hash = normalize_subject(subject)

    case Repo.one(
           from t in __MODULE__,
             where: t.mailbox_id == ^mailbox_id and t.subject_hash == ^subject_hash,
             select: t.id
         ) do
      nil ->
        # Create new thread (or resolve unique conflict from a concurrent insert).
        insert_result =
          %__MODULE__{}
          |> changeset(%{mailbox_id: mailbox_id, subject_hash: subject_hash})
          |> Repo.insert()

        case insert_result do
          {:ok, thread} ->
            thread.id

          {:error, _changeset} ->
            Repo.one(
              from t in __MODULE__,
                where: t.mailbox_id == ^mailbox_id and t.subject_hash == ^subject_hash,
                select: t.id
            )
        end

      thread_id ->
        thread_id
    end
  end

  defp attach_parent_to_thread(parent_message_id, thread_id)
       when is_integer(parent_message_id) and is_integer(thread_id) do
    Repo.update_all(
      from(m in Message,
        where: m.id == ^parent_message_id and is_nil(m.thread_id)
      ),
      set: [thread_id: thread_id]
    )

    :ok
  end

  # Parse message ID from header (removes angle brackets)
  defp parse_message_id(nil), do: nil

  defp parse_message_id(message_id) do
    message_id
    |> String.trim()
    |> String.replace(~r/^<|>$/, "")
    |> case do
      "" -> nil
      id -> id
    end
  end

  defp parse_reference_ids(nil), do: []
  defp parse_reference_ids(""), do: []

  defp parse_reference_ids(references) when is_list(references) do
    references
    |> Enum.map(&parse_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp parse_reference_ids(references) when is_binary(references) do
    references
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&parse_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp parse_reference_ids(_), do: []

  defp message_id_candidates(nil), do: []
  defp message_id_candidates(""), do: []

  defp message_id_candidates(message_id) do
    normalized = parse_message_id(message_id)

    case normalized do
      nil -> []
      id -> Enum.uniq([id, "<#{id}>"])
    end
  end

  @doc """
  Gets a thread by ID with its messages.
  """
  def get_thread(thread_id, mailbox_id) do
    Repo.one(
      from t in __MODULE__,
        where: t.id == ^thread_id and t.mailbox_id == ^mailbox_id,
        preload: [messages: ^from(m in Message, order_by: m.inserted_at)]
    )
  end

  @doc """
  Gets all message IDs in a thread.

  When `mailbox_id` is provided, the lookup is scoped to that mailbox and will
  fall back to a singleton thread for legacy messages without `thread_id`.
  """
  def get_thread_message_ids(thread_id, mailbox_id \\ nil)

  def get_thread_message_ids(thread_id, mailbox_id)
      when is_integer(thread_id) and is_integer(mailbox_id) do
    thread_ids =
      Repo.all(
        from m in Message,
          where: m.mailbox_id == ^mailbox_id and m.thread_id == ^thread_id,
          select: m.id,
          order_by: m.inserted_at
      )

    if thread_ids == [] do
      Repo.all(
        from m in Message,
          where: m.mailbox_id == ^mailbox_id and m.id == ^thread_id and is_nil(m.thread_id),
          select: m.id,
          order_by: m.inserted_at
      )
    else
      thread_ids
    end
  end

  def get_thread_message_ids(thread_id, _mailbox_id) when is_integer(thread_id) do
    Repo.all(
      from m in Message,
        where: m.thread_id == ^thread_id,
        select: m.id,
        order_by: m.inserted_at
    )
  end

  def get_thread_message_ids(_thread_id, _mailbox_id), do: []
end
