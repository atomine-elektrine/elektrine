defmodule Elektrine.Social.Polls do
  @moduledoc """
  Poll creation, voting, and results.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.Outbox
  alias Elektrine.Async
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.Poll
  alias Elektrine.Social.PollOption
  alias Elektrine.Social.PollVote

  @doc """
  Creates a poll for a discussion post.
  """
  def create_poll(message_id, question, options, opts \\ []) do
    closes_at = Keyword.get(opts, :closes_at)
    allow_multiple = Keyword.get(opts, :allow_multiple, false)
    hide_totals = Keyword.get(opts, :hide_totals, false)
    options = normalize_poll_options(options)

    with :ok <- validate_poll_options(options),
         :ok <- validate_poll_expiration(closes_at) do
      Repo.transaction(fn ->
        create_poll_transaction(
          message_id,
          question,
          closes_at,
          allow_multiple,
          hide_totals,
          options
        )
      end)
    end
  end

  defp create_poll_transaction(
         message_id,
         question,
         closes_at,
         allow_multiple,
         hide_totals,
         options
       ) do
    case insert_poll(message_id, question, closes_at, allow_multiple, hide_totals) do
      {:ok, poll} ->
        poll_options = insert_poll_options(poll.id, options)
        %{poll | options: poll_options}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp insert_poll(message_id, question, closes_at, allow_multiple, hide_totals) do
    poll_attrs = %{
      message_id: message_id,
      question: question,
      closes_at: closes_at,
      allow_multiple: allow_multiple,
      hide_totals: hide_totals
    }

    %Poll{}
    |> Poll.changeset(poll_attrs)
    |> Repo.insert()
  end

  defp insert_poll_options(poll_id, options) do
    options
    |> Enum.with_index()
    |> Enum.map(fn {option_text, position} ->
      option_attrs = %{poll_id: poll_id, option_text: option_text, position: position}

      case %PollOption{} |> PollOption.changeset(option_attrs) |> Repo.insert() do
        {:ok, poll_option} -> poll_option
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Votes on a poll option.
  """
  def vote_on_poll(poll_id, option_id, user_id) do
    poll = Repo.get!(Poll, poll_id) |> Repo.preload([:options, :message])

    with :ok <- validate_poll_vote_target(poll, option_id, user_id) do
      existing_votes = list_poll_votes_for_user(poll_id, user_id)
      result = apply_poll_vote(poll, poll_id, option_id, user_id, existing_votes)
      finalize_poll_vote_result(result, poll, option_id, user_id)
    end
  end

  defp validate_poll_vote_target(poll, option_id, user_id) do
    cond do
      Poll.closed?(poll) -> {:error, :poll_closed}
      poll.message && poll.message.sender_id == user_id -> {:error, :self_vote}
      not Enum.any?(poll.options, &(&1.id == option_id)) -> {:error, :invalid_option}
      true -> :ok
    end
  end

  defp list_poll_votes_for_user(poll_id, user_id) do
    from(v in PollVote, where: v.poll_id == ^poll_id and v.user_id == ^user_id)
    |> Repo.all()
  end

  defp apply_poll_vote(_poll, poll_id, option_id, user_id, []),
    do: create_poll_vote(poll_id, option_id, user_id)

  defp apply_poll_vote(
         %Poll{allow_multiple: false},
         _poll_id,
         option_id,
         _user_id,
         existing_votes
       ) do
    existing_vote = List.first(existing_votes)

    if existing_vote.option_id == option_id,
      do: remove_poll_vote(existing_vote),
      else: change_poll_vote(existing_vote, option_id)
  end

  defp apply_poll_vote(%Poll{allow_multiple: true}, poll_id, option_id, user_id, existing_votes) do
    case Enum.find(existing_votes, &(&1.option_id == option_id)) do
      nil -> create_poll_vote(poll_id, option_id, user_id)
      existing_vote -> remove_poll_vote(existing_vote)
    end
  end

  defp finalize_poll_vote_result({:ok, vote}, poll, option_id, user_id) do
    maybe_federate_poll_vote(poll, option_id, user_id)
    {:ok, vote}
  end

  defp finalize_poll_vote_result(other, _poll, _option_id, _user_id), do: other

  def get_poll(poll_id) do
    Poll
    |> Repo.get(poll_id)
    |> case do
      %Poll{} = poll ->
        {:ok, Repo.preload(poll, [:options, message: [:sender, :remote_actor]])}

      nil ->
        {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def set_poll_votes(poll_id, option_ids, user_id)
      when is_list(option_ids) and is_integer(user_id) do
    with {:ok, %Poll{} = poll} <- get_poll(poll_id),
         normalized_option_ids <- normalize_poll_vote_option_ids(option_ids),
         :ok <- validate_poll_vote_set(poll, normalized_option_ids, user_id) do
      Repo.transaction(fn ->
        existing_votes = list_poll_votes_for_user(poll.id, user_id)
        existing_option_ids = Enum.map(existing_votes, & &1.option_id)
        desired_option_ids = normalized_poll_vote_set(poll, normalized_option_ids)
        remove_stale_poll_votes(existing_votes, desired_option_ids)

        inserted_votes =
          insert_missing_poll_votes(poll.id, desired_option_ids -- existing_option_ids, user_id)

        refresh_poll_counts(poll.id, existing_option_ids ++ desired_option_ids)
        Enum.each(inserted_votes, &maybe_federate_poll_vote(poll, &1.option_id, user_id))

        Poll
        |> Repo.get!(poll.id)
        |> Repo.preload([:options, message: [:sender, :remote_actor]])
      end)
    end
  end

  def set_poll_votes(_poll_id, _option_ids, _user_id), do: {:error, :invalid_vote}

  def clear_poll_votes(poll_id, user_id) when is_integer(user_id) do
    with {:ok, %Poll{} = poll} <- get_poll(poll_id) do
      Repo.transaction(fn ->
        existing_votes = list_poll_votes_for_user(poll.id, user_id)
        remove_stale_poll_votes(existing_votes, [])
        refresh_poll_counts(poll.id, Enum.map(existing_votes, & &1.option_id))

        Poll
        |> Repo.get!(poll.id)
        |> Repo.preload([:options, message: [:sender, :remote_actor]])
      end)
    end
  end

  def clear_poll_votes(_poll_id, _user_id), do: {:error, :not_found}

  defp normalize_poll_vote_option_ids(option_ids) do
    option_ids
    |> List.wrap()
    |> Enum.map(&parse_poll_vote_option_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp parse_poll_vote_option_id(value) when is_integer(value) and value > 0, do: value

  defp parse_poll_vote_option_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp parse_poll_vote_option_id(_value), do: nil

  defp validate_poll_vote_set(%Poll{} = poll, option_ids, user_id) do
    valid_option_ids = MapSet.new(Enum.map(poll.options || [], & &1.id))

    cond do
      option_ids == [] ->
        {:error, :invalid_vote}

      Poll.closed?(poll) ->
        {:error, :poll_closed}

      poll.message && poll.message.sender_id == user_id ->
        {:error, :self_vote}

      Enum.any?(option_ids, &(not MapSet.member?(valid_option_ids, &1))) ->
        {:error, :invalid_option}

      not poll.allow_multiple and length(option_ids) > 1 ->
        {:error, :multiple_votes_not_allowed}

      true ->
        :ok
    end
  end

  defp normalized_poll_vote_set(%Poll{allow_multiple: true}, option_ids), do: option_ids
  defp normalized_poll_vote_set(%Poll{}, [option_id | _]), do: [option_id]

  defp remove_stale_poll_votes(existing_votes, desired_option_ids) do
    desired_option_ids = MapSet.new(desired_option_ids)

    existing_votes
    |> Enum.reject(&MapSet.member?(desired_option_ids, &1.option_id))
    |> Enum.each(&Repo.delete!/1)
  end

  defp insert_missing_poll_votes(poll_id, option_ids, user_id) do
    Enum.map(option_ids, fn option_id ->
      %PollVote{}
      |> PollVote.changeset(%{poll_id: poll_id, option_id: option_id, user_id: user_id})
      |> Repo.insert!()
    end)
  end

  defp refresh_poll_counts(_poll_id, []), do: :ok

  defp refresh_poll_counts(poll_id, option_ids) do
    option_ids
    |> Enum.uniq()
    |> Enum.each(&update_poll_counts(poll_id, &1))
  end

  # Federates poll vote to remote instance if applicable
  defp maybe_federate_poll_vote(poll, option_id, user_id) do
    message = poll.message || Repo.get(Message, poll.message_id)

    with %Message{federated: true} = message <- message,
         option when not is_nil(option) <- Enum.find(poll.options, &(&1.id == option_id)) do
      preloaded_message = Repo.preload(message, :remote_actor)
      user = Accounts.get_user!(user_id)

      Async.start(fn ->
        Outbox.federate_poll_vote(poll, option, user, preloaded_message)
      end)
    end
  end

  @doc """
  Gets poll results with vote counts and percentages.
  """
  def get_poll_results(poll_id) do
    poll =
      Repo.get!(Poll, poll_id)
      |> Repo.preload(:options)

    options_with_votes =
      Enum.map(poll.options, fn option ->
        vote_count = option.vote_count

        percentage =
          if poll.total_votes > 0 do
            Float.round(vote_count / poll.total_votes * 100, 1)
          else
            0.0
          end

        %{
          id: option.id,
          text: option.option_text,
          vote_count: vote_count,
          percentage: percentage,
          position: option.position
        }
      end)
      |> Enum.sort_by(& &1.position)

    %{
      poll_id: poll.id,
      question: poll.question,
      total_votes: poll.total_votes,
      closes_at: poll.closes_at,
      allow_multiple: poll.allow_multiple,
      is_open: Poll.open?(poll),
      options: options_with_votes
    }
  end

  @doc """
  Gets user's votes on a poll.
  """
  def get_user_poll_votes(poll_id, user_id) do
    from(v in PollVote,
      where: v.poll_id == ^poll_id and v.user_id == ^user_id,
      select: v.option_id
    )
    |> Repo.all()
  end

  # Private poll helper functions

  defp create_poll_vote(poll_id, option_id, user_id) do
    case %PollVote{}
         |> PollVote.changeset(%{
           poll_id: poll_id,
           option_id: option_id,
           user_id: user_id
         })
         |> Repo.insert() do
      {:ok, vote} ->
        update_poll_counts(poll_id, option_id)
        {:ok, vote}

      error ->
        error
    end
  end

  defp remove_poll_vote(vote) do
    case Repo.delete(vote) do
      {:ok, deleted_vote} ->
        update_poll_counts(deleted_vote.poll_id, deleted_vote.option_id)
        {:ok, deleted_vote}

      error ->
        error
    end
  end

  defp change_poll_vote(vote, new_option_id) do
    old_option_id = vote.option_id

    case vote
         |> PollVote.changeset(%{option_id: new_option_id})
         |> Repo.update() do
      {:ok, updated_vote} ->
        # Decrement old option, increment new option
        update_poll_counts(vote.poll_id, old_option_id)
        update_poll_counts(vote.poll_id, new_option_id)
        {:ok, updated_vote}

      error ->
        error
    end
  end

  defp update_poll_counts(poll_id, option_id) do
    # Recalculate option vote count
    option_vote_count =
      from(v in PollVote,
        where: v.option_id == ^option_id,
        select: count(v.id)
      )
      |> Repo.one()

    from(o in PollOption, where: o.id == ^option_id)
    |> Repo.update_all(set: [vote_count: option_vote_count])

    # Recalculate total poll votes
    total_votes =
      from(v in PollVote,
        where: v.poll_id == ^poll_id,
        select: count(v.id)
      )
      |> Repo.one()

    voters_count =
      from(v in PollVote,
        where: v.poll_id == ^poll_id,
        select: count(fragment("distinct ?", v.user_id))
      )
      |> Repo.one()

    from(p in Poll, where: p.id == ^poll_id)
    |> Repo.update_all(set: [total_votes: total_votes, voters_count: voters_count])

    # Broadcast poll update
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "poll:#{poll_id}",
      {:poll_updated, poll_id}
    )
  end

  defp normalize_poll_options(options) when is_list(options) do
    options
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_poll_options(_), do: []

  defp validate_poll_options(options) do
    cond do
      length(options) < 2 ->
        {:error, "Poll must have at least 2 options"}

      length(options) > 4 ->
        {:error, "Poll can have at most 4 options"}

      Enum.any?(options, &(String.length(&1) > 50)) ->
        {:error, "Poll options must be at most 50 characters"}

      Enum.uniq_by(options, &String.downcase/1) |> length() != length(options) ->
        {:error, "Poll options must be unique"}

      true ->
        :ok
    end
  end

  defp validate_poll_expiration(nil), do: :ok

  defp validate_poll_expiration(%DateTime{} = closes_at) do
    seconds_until_close = DateTime.diff(closes_at, DateTime.utc_now(), :second)

    cond do
      seconds_until_close < 300 -> {:error, "Poll duration must be at least 5 minutes"}
      seconds_until_close > 31 * 24 * 60 * 60 -> {:error, "Poll duration must be at most 1 month"}
      true -> :ok
    end
  end

  defp validate_poll_expiration(_), do: {:error, "Invalid poll expiration"}
end
