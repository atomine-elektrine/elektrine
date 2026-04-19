defmodule Elektrine.Components.ReportModal do
  @moduledoc false
  use Phoenix.LiveComponent

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
    cooldown = Reports.get_report_cooldown(socket.assigns.reporter_id)
    {:ok, assign(socket, :cooldown_remaining, cooldown)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box modal-surface max-w-md">
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
            <div class="select select-bordered w-full">
              <select
                name="reason"
                value={@reason}
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
              <span class="label-text-alt">{String.length(@description || "")}/5000 characters</span>
            </label>
          </div>

          <div class="alert alert-info mb-6 shadow-sm">
            <.icon name="hero-information-circle" class="w-4 h-4" />
            <div>
              <p class="text-sm">Moderators will review this report and take action if needed.</p>
              <p class="text-xs opacity-70">
                Please report in good faith. Repeated false reports may limit reporting access.
              </p>
            </div>
          </div>

          <%= if @cooldown_remaining > 0 do %>
            <div class="alert alert-warning mb-6 shadow-sm">
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
                  <.spinner class="mr-2" /> Submitting...
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

    case Reports.can_user_report?(socket.assigns.reporter_id) do
      {:error, error_message} ->
        {:noreply, socket |> assign(submitting: false) |> assign(error_message: error_message)}

      {:ok, true} ->
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
          metadata =
            Reports.build_metadata(socket.assigns.reportable_type, socket.assigns.reportable_id)
            |> Map.merge(socket.assigns[:additional_metadata] || %{})

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

  attr :name, :string, required: true
  attr :class, :string, default: nil

  defp icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={["ui-icon", @name, @class]} />
    """
  end

  attr :class, :string, default: nil

  defp spinner(assigns) do
    ~H"""
    <svg
      class={["animate-spin", "w-4 h-4", @class]}
      viewBox="0 0 24 24"
      xmlns="http://www.w3.org/2000/svg"
      fill="currentColor"
      aria-hidden="true"
      role="status"
      aria-label="Loading"
    >
      <path
        fill="currentColor"
        d="M20.27,4.74a4.93,4.93,0,0,1,1.52,4.61,5.32,5.32,0,0,1-4.1,4.51,5.12,5.12,0,0,1-5.2-1.5,5.53,5.53,0,0,0,6.13-1.48A5.66,5.66,0,0,0,20.27,4.74ZM12.32,11.53a5.49,5.49,0,0,0-1.47-6.2A5.57,5.57,0,0,0,4.71,3.72,5.17,5.17,0,0,1,9.53,2.2,5.52,5.52,0,0,1,13.9,6.45,5.28,5.28,0,0,1,12.32,11.53ZM19.2,20.29a4.92,4.92,0,0,1-4.72,1.49,5.32,5.32,0,0,1-4.34-4.05A5.2,5.2,0,0,1,11.6,12.5a5.6,5.6,0,0,0,1.51,6.13A5.63,5.63,0,0,0,19.2,20.29ZM3.79,19.38A5.18,5.18,0,0,1,2.32,14a5.3,5.3,0,0,1,4.59-4,5,5,0,0,1,4.58,1.61,5.55,5.55,0,0,0-6.32,1.69A5.46,5.46,0,0,0,3.79,19.38ZM12.23,12a5.11,5.11,0,0,0,3.66-5,5.75,5.75,0,0,0-3.18-6,5,5,0,0,1,4.42,2.3,5.21,5.21,0,0,1,.24,5.92A5.4,5.4,0,0,1,12.23,12ZM11.76,12a5.18,5.18,0,0,0-3.68,5.09,5.58,5.58,0,0,0,3.19,5.79c-1,.35-2.9-.46-4-1.68A5.51,5.51,0,0,1,11.76,12ZM23,12.63a5.07,5.07,0,0,1-2.35,4.52,5.23,5.23,0,0,1-5.91.2,5.24,5.24,0,0,1-2.67-4.77,5.51,5.51,0,0,0,5.45,3.33A5.52,5.52,0,0,0,23,12.63ZM1,11.23a5,5,0,0,1,2.49-4.5,5.23,5.23,0,0,1,5.81-.06,5.3,5.3,0,0,1,2.61,4.74A5.56,5.56,0,0,0,6.56,8.06,5.71,5.71,0,0,0,1,11.23Z"
      />
    </svg>
    """
  end
end
