defmodule ElektrineWeb.Components.Social.Poll do
  @moduledoc """
  Poll rendering component for discussion posts.
  """
  use Phoenix.Component

  attr :poll, :map, required: true
  attr :current_user, :map, default: nil
  attr :user_votes, :list, default: []

  def poll_display(assigns) do
    ~H"""
    <div class="poll-container border border-base-300 rounded-lg p-4 my-4 bg-base-100">
      <h4 class="font-semibold text-lg mb-3">{@poll.question}</h4>

      <div class="space-y-2">
        <%= for option <- @poll.options do %>
          <div class="poll-option">
            <%= if @current_user && @poll.is_open do %>
              <button
                phx-click="vote_poll"
                phx-value-poll-id={@poll.poll_id}
                phx-value-option-id={option.id}
                class={"btn btn-sm w-full justify-start relative overflow-hidden #{if option.id in @user_votes, do: "btn-primary", else: "btn-ghost"}"}
              >
                <!-- Progress bar background -->
                <div class="absolute inset-0 bg-primary/20" style={"width: #{option.percentage}%"}>
                </div>
                
    <!-- Option content -->
                <div class="relative z-10 flex justify-between w-full">
                  <span class="flex items-center gap-2">
                    <%= if option.id in @user_votes do %>
                      <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
                        <path
                          fill-rule="evenodd"
                          d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                          clip-rule="evenodd"
                        >
                        </path>
                      </svg>
                    <% end %>
                    {option.text}
                  </span>
                  <span class="font-semibold">
                    {option.vote_count} ({option.percentage}%)
                  </span>
                </div>
              </button>
            <% else %>
              <!-- Results-only view (poll closed or not logged in) -->
              <div class="relative overflow-hidden rounded-lg border border-base-300 p-3 bg-base-50">
                <!-- Progress bar -->
                <div class="absolute inset-0 bg-primary/10" style={"width: #{option.percentage}%"}>
                </div>
                
    <!-- Option content -->
                <div class="relative z-10 flex justify-between">
                  <span class="font-medium">{option.text}</span>
                  <span class="font-semibold">
                    {option.vote_count} ({option.percentage}%)
                  </span>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
      
    <!-- Poll footer -->
      <div class="mt-4 pt-3 border-t border-base-200 flex items-center justify-between text-sm opacity-70">
        <div>
          <span class="font-medium">{@poll.total_votes}</span>
          total votes
          <%= if @poll.allow_multiple do %>
            <span class="ml-2 badge badge-sm">Multiple choice</span>
          <% end %>
        </div>
        <div>
          <%= if @poll.closes_at do %>
            <%= if @poll.is_open do %>
              <span>Closes {format_poll_time(@poll.closes_at)}</span>
            <% else %>
              <span class="text-error">Poll closed</span>
            <% end %>
          <% else %>
            <span>No end date</span>
          <% end %>
        </div>
      </div>

      <%= if !@current_user && @poll.is_open do %>
        <div class="alert alert-info mt-3">
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
            >
            </path>
          </svg>
          <span>Sign in to vote on this poll</span>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_poll_time(datetime) when is_nil(datetime), do: ""

  defp format_poll_time(%DateTime{} = datetime) do
    diff = DateTime.diff(datetime, DateTime.utc_now(), :second)

    cond do
      diff < 0 -> "already closed"
      diff < 3600 -> "in #{div(diff, 60)} minutes"
      diff < 86_400 -> "in #{div(diff, 3600)} hours"
      diff < 604_800 -> "in #{div(diff, 86400)} days"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end

  defp format_poll_time(_), do: ""
end
