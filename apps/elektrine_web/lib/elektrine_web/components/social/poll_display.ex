defmodule ElektrineWeb.Components.Social.PollDisplay do
  @moduledoc """
  Displays polls from both local Poll structs and remote ActivityPub objects.
  """

  use Phoenix.Component
  import ElektrineWeb.CoreComponents

  # For local polls (Poll struct)
  attr(:poll, :map, default: nil)
  attr(:message, :map, default: nil)
  attr(:current_user, :map, default: nil)
  attr(:user_votes, :list, default: [])
  attr(:interactive, :boolean, default: true)
  # Fresh remote poll data (from ActivityPub fetch) - overrides local poll data when present
  attr(:remote_poll_data, :map, default: nil)

  # For remote ActivityPub polls
  attr(:post, :map, default: nil)
  attr(:remote_actor, :map, default: nil)

  def poll_card(assigns) do
    # Detect if this is a remote ActivityPub poll or a local poll
    cond do
      assigns.post != nil ->
        render_remote_poll(assigns)

      assigns.poll != nil ->
        render_local_poll(assigns)

      true ->
        ~H""
    end
  end

  # Render a local Poll struct
  defp render_local_poll(assigns) do
    is_open = Elektrine.Social.Poll.open?(assigns.poll)

    # If we have fresh remote poll data, use it to override local vote counts
    # Build a map of option_text => remote_votes for merging
    remote_votes_map =
      case assigns.remote_poll_data do
        %{options: remote_options} when is_list(remote_options) ->
          Map.new(remote_options, fn opt -> {opt.name, opt.votes} end)

        _ ->
          %{}
      end

    # Use remote total_votes if available, otherwise calculate from local data
    total_votes =
      case assigns.remote_poll_data do
        %{total_votes: remote_total} when is_integer(remote_total) and remote_total > 0 ->
          remote_total

        _ ->
          stored_total = assigns.poll.total_votes || 0

          calculated_total =
            Enum.reduce(assigns.poll.options, 0, fn opt, acc -> acc + (opt.vote_count || 0) end)

          if stored_total > 0, do: stored_total, else: calculated_total
      end

    assigns =
      assigns
      |> assign(:is_open, is_open)
      |> assign(:remote_votes_map, remote_votes_map)
      |> assign(:total_votes, total_votes)

    ~H"""
    <div class="border border-base-300 rounded-lg p-4 bg-base-50 dark:bg-base-200/50">
      <!-- Poll Question -->
      <div class="mb-4">
        <div class="flex items-start gap-2 mb-2">
          <.icon name="hero-chart-bar" class="w-5 h-5 text-primary flex-shrink-0 mt-0.5" />
          <div class="flex-1">
            <h3 class="font-semibold text-base">{@poll.question}</h3>
          </div>
        </div>

        <%= if @message && @message.federated && @is_open do %>
          <p class="text-xs opacity-70 mb-2">
            <.icon name="hero-globe-alt" class="w-3 h-3 inline" />
            Federated poll - your vote will be sent to the original instance
          </p>
        <% end %>
      </div>
      
    <!-- Poll Options -->
      <div class="space-y-2">
        <%= for option <- @poll.options do %>
          <% # Use remote vote count if available, otherwise use local
          vote_count = Map.get(@remote_votes_map, option.option_text, option.vote_count || 0)

          percentage =
            if @total_votes > 0 do
              Float.round(vote_count / @total_votes * 100, 1)
            else
              0
            end

          is_voted = option.id in @user_votes
          can_vote = @interactive && @is_open && @current_user %>

          <%= if can_vote do %>
            <button
              type="button"
              phx-click="vote_poll"
              phx-value-poll_id={@poll.id}
              phx-value-option_id={option.id}
              class={[
                "relative overflow-hidden rounded-lg border transition-colors w-full text-left cursor-pointer hover:border-primary/50",
                if(is_voted, do: "border-primary bg-primary/10", else: "border-base-300 bg-base-100")
              ]}
            >
              <div
                class="absolute inset-0 bg-primary/20 transition-all pointer-events-none"
                style={"width: #{percentage}%"}
              >
              </div>
              <div class="relative px-4 py-3 flex items-center justify-between">
                <div class="flex items-center gap-2 flex-1">
                  <%= if is_voted do %>
                    <.icon name="hero-check-circle" class="w-4 h-4 text-primary flex-shrink-0" />
                  <% else %>
                    <.icon name="hero-stop" class="w-4 h-4 opacity-40 flex-shrink-0" />
                  <% end %>
                  <span class="font-medium">{option.option_text}</span>
                </div>
                <div class="flex items-center gap-2 text-sm">
                  <span class="font-semibold">{percentage}%</span>
                  <span class="opacity-60">({vote_count})</span>
                </div>
              </div>
            </button>
          <% else %>
            <.poll_option_display
              percentage={percentage}
              is_voted={is_voted}
              option_text={option.option_text}
              vote_count={vote_count}
            />
          <% end %>
        <% end %>
      </div>
      
    <!-- Poll Stats -->
      <div class="mt-4 flex items-center justify-between text-xs opacity-70">
        <span>{@total_votes} {if @total_votes == 1, do: "vote", else: "votes"}</span>
        <span>
          <%= if @poll.closes_at do %>
            <%= if Elektrine.Social.Poll.closed?(@poll) do %>
              Poll closed
            <% else %>
              <% hours_left = calculate_hours_left(@poll.closes_at) %>
              {format_time_remaining(hours_left)}
            <% end %>
          <% else %>
            No end time
          <% end %>
        </span>
      </div>
      
    <!-- Link to original for federated polls -->
      <%= if @message && @message.federated && @message.activitypub_url do %>
        <a
          href={@message.activitypub_url}
          target="_blank"
          rel="noopener noreferrer"
          class="btn btn-sm btn-ghost btn-primary w-full mt-3"
        >
          <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4 mr-2" />
          View on {if @message.remote_actor,
            do: @message.remote_actor.domain,
            else: "original instance"}
        </a>
      <% end %>

      <%= if @interactive && !@current_user && @is_open do %>
        <p class="text-xs text-center opacity-70 mt-2">Sign in to vote on this poll</p>
      <% end %>
    </div>
    """
  end

  # Render a remote ActivityPub poll (Question type)
  defp render_remote_poll(assigns) do
    options = assigns.post["oneOf"] || assigns.post["anyOf"] || []
    allow_multiple = !is_nil(assigns.post["anyOf"])

    total_votes =
      Enum.reduce(options, 0, fn option, acc ->
        acc + extract_vote_count(option)
      end)

    end_time = assigns.post["endTime"] || assigns.post["closed"]
    is_closed = poll_closed?(end_time)

    # Get domain from remote_actor or parse from post id
    domain =
      cond do
        assigns.remote_actor -> assigns.remote_actor.domain
        assigns.post["id"] -> URI.parse(assigns.post["id"]).host
        true -> nil
      end

    can_vote = assigns.interactive && !is_closed && assigns.current_user != nil

    assigns =
      assigns
      |> assign(:options, options)
      |> assign(:allow_multiple, allow_multiple)
      |> assign(:total_votes, total_votes)
      |> assign(:is_closed, is_closed)
      |> assign(:end_time, end_time)
      |> assign(:domain, domain)
      |> assign(:can_vote, can_vote)

    ~H"""
    <div class="border border-base-300 rounded-lg p-4 bg-base-50 dark:bg-base-200/50">
      <!-- Poll Header -->
      <div class="flex items-center gap-2 mb-4">
        <.icon name="hero-chart-bar" class="w-5 h-5 text-primary" />
        <span class="font-semibold">Poll</span>
        <%= if @allow_multiple do %>
          <span class="badge badge-sm badge-ghost">Multiple choice</span>
        <% end %>
        <%= if @is_closed do %>
          <span class="badge badge-sm badge-error">Closed</span>
        <% end %>
      </div>
      
    <!-- Poll Options -->
      <div class="space-y-2">
        <%= for {option, idx} <- Enum.with_index(@options) do %>
          <% vote_count = extract_vote_count(option)

          percentage =
            if @total_votes > 0, do: Float.round(vote_count / @total_votes * 100, 1), else: 0

          option_text = option["name"] || "Option" %>
          <%= if @can_vote do %>
            <button
              type="button"
              phx-click="vote_remote_poll"
              phx-value-option_name={option_text}
              phx-value-option_index={idx}
              class="relative overflow-hidden rounded-lg border transition-colors w-full text-left cursor-pointer hover:border-primary/50 border-base-300 bg-base-100"
            >
              <div
                class="absolute inset-0 bg-primary/20 transition-all pointer-events-none"
                style={"width: #{percentage}%"}
              >
              </div>
              <div class="relative px-4 py-3 flex items-center justify-between">
                <div class="flex items-center gap-2 flex-1">
                  <.icon name="hero-stop" class="w-4 h-4 opacity-40 flex-shrink-0" />
                  <span class="font-medium">{option_text}</span>
                </div>
                <div class="flex items-center gap-2 text-sm">
                  <span class="font-semibold">{percentage}%</span>
                  <span class="opacity-60">({vote_count})</span>
                </div>
              </div>
            </button>
          <% else %>
            <.poll_option_display
              percentage={percentage}
              is_voted={false}
              option_text={option_text}
              vote_count={vote_count}
            />
          <% end %>
        <% end %>
      </div>
      
    <!-- Poll Stats -->
      <div class="mt-4 flex items-center justify-between text-xs opacity-70">
        <span>{@total_votes} {if @total_votes == 1, do: "vote", else: "votes"}</span>
        <span>
          <%= if @is_closed do %>
            Poll closed
          <% else %>
            <%= if @end_time do %>
              <% hours_left = calculate_hours_left_from_string(@end_time) %>
              {format_time_remaining(hours_left)}
            <% else %>
              No end time
            <% end %>
          <% end %>
        </span>
      </div>
      
    <!-- Info for logged in users -->
      <%= if @can_vote do %>
        <p class="text-xs text-center opacity-70 mt-3">
          <.icon name="hero-globe-alt" class="w-3 h-3 inline" />
          Click an option to vote (sent to {@domain})
        </p>
      <% else %>
        <%= if @interactive && !@is_closed && !@current_user do %>
          <p class="text-xs text-center opacity-70 mt-3">Sign in to vote on this poll</p>
        <% end %>
      <% end %>
    </div>
    """
  end

  # Shared component for displaying a poll option (non-interactive)
  attr(:percentage, :float, required: true)
  attr(:is_voted, :boolean, required: true)
  attr(:option_text, :string, required: true)
  attr(:vote_count, :integer, required: true)

  defp poll_option_display(assigns) do
    ~H"""
    <div class={[
      "relative overflow-hidden rounded-lg border transition-colors",
      if(@is_voted, do: "border-primary bg-primary/10", else: "border-base-300 bg-base-100")
    ]}>
      <div
        class="absolute inset-0 bg-primary/20 transition-all pointer-events-none"
        style={"width: #{@percentage}%"}
      >
      </div>
      <div class="relative px-4 py-3 flex items-center justify-between">
        <div class="flex items-center gap-2 flex-1">
          <%= if @is_voted do %>
            <.icon name="hero-check-circle" class="w-4 h-4 text-primary flex-shrink-0" />
          <% else %>
            <.icon name="hero-stop" class="w-4 h-4 opacity-40 flex-shrink-0" />
          <% end %>
          <span class="font-medium">{@option_text}</span>
        </div>
        <div class="flex items-center gap-2 text-sm">
          <span class="font-semibold">{@percentage}%</span>
          <span class="opacity-60">({@vote_count})</span>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions

  defp extract_vote_count(option) do
    case option["replies"] do
      %{"totalItems" => count} when is_integer(count) ->
        count

      %{"totalItems" => count} when is_binary(count) ->
        case Integer.parse(count) do
          {n, _} -> n
          :error -> 0
        end

      %{} = replies ->
        replies["totalItems"] || 0

      _ ->
        0
    end
  end

  defp poll_closed?(nil), do: false

  defp poll_closed?(time_str) when is_binary(time_str) do
    case DateTime.from_iso8601(time_str) do
      {:ok, dt, _} -> DateTime.compare(DateTime.utc_now(), dt) != :lt
      _ -> false
    end
  end

  defp poll_closed?(_), do: false

  defp calculate_hours_left(closes_at) when is_struct(closes_at, NaiveDateTime) do
    now = DateTime.utc_now()
    closes = DateTime.from_naive!(closes_at, "Etc/UTC")
    div(DateTime.diff(closes, now), 3600)
  end

  defp calculate_hours_left(_), do: 0

  defp calculate_hours_left_from_string(time_str) when is_binary(time_str) do
    case DateTime.from_iso8601(time_str) do
      {:ok, dt, _} -> max(0, div(DateTime.diff(dt, DateTime.utc_now()), 3600))
      _ -> 0
    end
  end

  defp calculate_hours_left_from_string(_), do: 0

  defp format_time_remaining(hours_left) when hours_left > 24,
    do: "Closes in #{div(hours_left, 24)} days"

  defp format_time_remaining(hours_left) when hours_left > 0, do: "Closes in #{hours_left} hours"
  defp format_time_remaining(_), do: "Closes soon"
end
