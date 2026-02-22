defmodule ElektrineWeb.Components.ReportModal do
  @moduledoc false
  use ElektrineWeb, :live_component
  alias Elektrine.Reports

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:reason, "")
     |> assign(:description, "")
     |> assign(:submitting, false)
     |> assign(:error_message, nil)
     |> assign(:cooldown_remaining, 0)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # Check cooldown when modal opens
    cooldown = Reports.get_report_cooldown(socket.assigns.reporter_id)
    socket = assign(socket, :cooldown_remaining, cooldown)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-md">
        <h3 class="font-bold text-lg mb-6 text-center text-error">
          Report {format_reportable_type(@reportable_type)}
        </h3>

        <%= if @error_message do %>
          <div class="alert alert-error mb-6">
            <.icon name="hero-exclamation-circle" class="w-4 h-4" />
            <span>{@error_message}</span>
          </div>
        <% end %>

        <form phx-submit="submit_report" phx-target={@myself}>
          <div class="form-control w-full mb-4">
            <label class="label">
              <span class="label-text font-medium">Reason for Report</span>
            </label>
            <select
              name="reason"
              value={@reason}
              class="select select-bordered w-full"
              required
              disabled={@submitting}
              phx-change="update_reason"
              phx-target={@myself}
            >
              <option value="" disabled selected={@reason == ""}>Select a reason...</option>
              <option value="spam" selected={@reason == "spam"}>Spam</option>
              <option value="harassment" selected={@reason == "harassment"}>
                Harassment or Bullying
              </option>
              <option value="inappropriate" selected={@reason == "inappropriate"}>
                Inappropriate Content
              </option>
              <option value="violence" selected={@reason == "violence"}>Violence or Threats</option>
              <option value="hate_speech" selected={@reason == "hate_speech"}>Hate Speech</option>
              <option value="impersonation" selected={@reason == "impersonation"}>
                Impersonation
              </option>
              <option value="self_harm" selected={@reason == "self_harm"}>
                Self-Harm or Suicide
              </option>
              <option value="misinformation" selected={@reason == "misinformation"}>
                Misinformation
              </option>
              <option value="other" selected={@reason == "other"}>Other</option>
            </select>
          </div>

          <div class="form-control w-full mb-6">
            <label class="label">
              <span class="label-text font-medium">Additional Details</span>
              <span class="label-text-alt">Optional</span>
            </label>
            <textarea
              name="description"
              placeholder="Provide more context about this report..."
              class="textarea textarea-bordered w-full"
              rows="4"
              maxlength="5000"
              disabled={@submitting}
              phx-change="update_description"
              phx-target={@myself}
            >{@description}</textarea>
            <label class="label">
              <span class="label-text-alt">
                {String.length(@description || "")}/5000 characters
              </span>
            </label>
          </div>

          <div class="alert alert-info mb-6">
            <.icon name="hero-information-circle" class="w-4 h-4" />
            <div>
              <p class="text-sm">Moderators will review this report and take action if needed.</p>
              <p class="text-xs opacity-70">
                Please report in good faith. Repeated false reports may limit reporting access.
              </p>
            </div>
          </div>

          <%= if @cooldown_remaining > 0 do %>
            <div class="alert alert-warning mb-6">
              <.icon name="hero-clock" class="w-4 h-4" />
              <span>Please wait {@cooldown_remaining} seconds before submitting another report.</span>
            </div>
          <% end %>

          <div class="modal-action justify-center gap-3">
            <button
              type="button"
              phx-click="close_report_modal"
              class="btn btn-ghost"
              disabled={@submitting}
            >
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-secondary"
              disabled={@submitting || @reason == "" || @cooldown_remaining > 0}
            >
              <%= cond do %>
                <% @cooldown_remaining > 0 -> %>
                  <.icon name="hero-clock" class="w-4 h-4 mr-2" /> Wait {@cooldown_remaining}s
                <% @submitting -> %>
                  <.spinner size="sm" class="mr-2" /> Submitting...
                <% true -> %>
                  <.icon name="hero-flag" class="w-4 h-4 mr-2" /> Submit Report
              <% end %>
            </button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="close_report_modal"></div>
    </div>
    """
  end

  @impl true
  def handle_event("update_reason", params, socket) do
    reason = params["reason"] || ""
    description = params["description"] || socket.assigns.description
    {:noreply, assign(socket, reason: reason, description: description)}
  end

  @impl true
  def handle_event("update_description", params, socket) do
    reason = params["reason"] || socket.assigns.reason
    description = params["description"] || ""
    {:noreply, assign(socket, reason: reason, description: description)}
  end

  @impl true
  def handle_event("submit_report", %{"reason" => reason, "description" => description}, socket) do
    socket = assign(socket, submitting: true, error_message: nil)

    # First check if user can report (rate limits, spam detection)
    case Reports.can_user_report?(socket.assigns.reporter_id) do
      {:error, error_message} ->
        {:noreply,
         socket
         |> assign(submitting: false)
         |> assign(error_message: error_message)}

      {:ok, true} ->
        # Check if already reported
        if Reports.already_reported?(
             socket.assigns.reporter_id,
             socket.assigns.reportable_type,
             socket.assigns.reportable_id
           ) do
          {:noreply,
           socket
           |> assign(submitting: false)
           |> assign(
             error_message:
               "You already reported this content. We'll keep your existing report in review."
           )}
        else
          # Build metadata
          metadata =
            Reports.build_metadata(
              socket.assigns.reportable_type,
              socket.assigns.reportable_id
            )

          # Add any additional context passed in
          metadata = Map.merge(metadata, socket.assigns[:additional_metadata] || %{})

          report_attrs = %{
            reporter_id: socket.assigns.reporter_id,
            reportable_type: socket.assigns.reportable_type,
            reportable_id: socket.assigns.reportable_id,
            reason: reason,
            description: description,
            metadata: metadata
          }

          case Reports.create_report(report_attrs) do
            {:ok, _report} ->
              send(
                self(),
                {:report_submitted, socket.assigns.reportable_type, socket.assigns.reportable_id}
              )

              {:noreply, socket}

            {:error, :rate_limited} ->
              {:noreply,
               socket
               |> assign(submitting: false)
               |> assign(
                 error_message: "You're sending reports too quickly. Please wait and try again."
               )}

            {:error, :spam_detected} ->
              {:noreply,
               socket
               |> assign(submitting: false)
               |> assign(
                 error_message:
                   "Reporting is temporarily limited on your account. Please try again later."
               )}

            {:error, _} ->
              {:noreply,
               socket
               |> assign(submitting: false)
               |> assign(error_message: "Couldn't submit your report. Please try again.")}
          end
        end
    end
  end

  defp format_reportable_type("user"), do: "User"
  defp format_reportable_type("message"), do: "Message"
  defp format_reportable_type("conversation"), do: "Conversation"
  defp format_reportable_type("post"), do: "Post"
  defp format_reportable_type(type), do: String.capitalize(type)
end
