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
    in_reply_to = attrs[:in_reply_to] || attrs["in_reply_to"]
    references = attrs[:references] || attrs["references"]
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
    message_id = parse_message_id(in_reply_to)

    case Repo.one(
           from m in Message,
             where: m.mailbox_id == ^mailbox_id and m.message_id == ^message_id,
             select: m.thread_id
         ) do
      nil -> nil
      thread_id -> thread_id
    end
  end

  # Find thread by References header
  defp find_thread_by_references(nil, _mailbox_id), do: nil
  defp find_thread_by_references("", _mailbox_id), do: nil

  defp find_thread_by_references(references, mailbox_id) do
    # Parse references into individual message IDs
    message_ids =
      references
      |> String.split(~r/\s+/)
      |> Enum.map(&parse_message_id/1)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(message_ids) do
      nil
    else
      # Find any message with these message_ids that has a thread
      Repo.one(
        from m in Message,
          where:
            m.mailbox_id == ^mailbox_id and m.message_id in ^message_ids and
              not is_nil(m.thread_id),
          select: m.thread_id,
          limit: 1
      )
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
        # Create new thread
        {:ok, thread} =
          %__MODULE__{}
          |> changeset(%{mailbox_id: mailbox_id, subject_hash: subject_hash})
          |> Repo.insert()

        thread.id

      thread_id ->
        thread_id
    end
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
  """
  def get_thread_message_ids(thread_id) do
    Repo.all(
      from m in Message,
        where: m.thread_id == ^thread_id,
        select: m.id,
        order_by: m.inserted_at
    )
  end
end
