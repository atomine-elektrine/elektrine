defmodule ElektrineWeb.API.PollJSON do
  @moduledoc false

  def format_poll(nil, _user_id), do: nil
  def format_poll(%Ecto.Association.NotLoaded{}, _user_id), do: nil

  def format_poll(poll, user_id) do
    own_votes = social().get_user_poll_votes(poll.id, user_id)
    expired = not poll_module().open?(poll)
    show_totals = not poll.hide_totals or expired or own_votes != []

    %{
      id: to_string(poll.id),
      expires_at: poll.closes_at,
      expired: expired,
      multiple: poll.allow_multiple || false,
      votes_count: if(show_totals, do: poll.total_votes || 0),
      voters_count: if(show_totals, do: poll.voters_count || poll.total_votes || 0),
      voted: own_votes != [],
      own_votes: Enum.map(own_votes, &to_string/1),
      options: Enum.map(sorted_options(poll.options || []), &format_option(&1, show_totals)),
      emojis: [],
      pleroma: %{
        non_anonymous: false
      }
    }
  end

  defp sorted_options(%Ecto.Association.NotLoaded{}), do: []
  defp sorted_options(options), do: Enum.sort_by(options, &{&1.position || 0, &1.id || 0})

  defp format_option(option, show_totals) do
    %{
      title: option.option_text,
      votes_count: if(show_totals, do: option.vote_count || 0)
    }
  end

  defp social, do: Module.concat([Elektrine, Social])
  defp poll_module, do: Module.concat([Elektrine, Social, Poll])
end
