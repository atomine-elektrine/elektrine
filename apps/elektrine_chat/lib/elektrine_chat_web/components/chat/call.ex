defmodule ElektrineChatWeb.Components.Chat.Call do
  @moduledoc false
  use Phoenix.Component

  attr :user, :map, default: nil
  attr :conversation_id, :string, default: nil
  attr :remote_handle, :string, default: nil

  def call_buttons(assigns) do
    ~H"""
    <div class="flex gap-1 sm:gap-2">
      <button
        type="button"
        phx-click="initiate_call"
        phx-value-user_id={@user && @user.id}
        phx-value-call_type="audio"
        phx-value-conversation_id={@conversation_id}
        phx-value-remote_handle={@remote_handle}
        class="btn btn-ghost btn-circle btn-sm p-0 min-h-0 h-8 w-8 sm:h-9 sm:w-9 flex-shrink-0"
        title="Audio call"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-4 w-4 sm:h-5 sm:w-5"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M3 5a2 2 0 012-2h3.28a1 1 0 01.948.684l1.498 4.493a1 1 0 01-.502 1.21l-2.257 1.13a11.042 11.042 0 005.516 5.516l1.13-2.257a1 1 0 011.21-.502l4.493 1.498a1 1 0 01.684.949V19a2 2 0 01-2 2h-1C9.716 21 3 14.284 3 6V5z"
          />
        </svg>
      </button>

      <button
        type="button"
        phx-click="initiate_call"
        phx-value-user_id={@user && @user.id}
        phx-value-call_type="video"
        phx-value-conversation_id={@conversation_id}
        phx-value-remote_handle={@remote_handle}
        class="btn btn-ghost btn-circle btn-sm p-0 min-h-0 h-8 w-8 sm:h-9 sm:w-9 hidden sm:flex flex-shrink-0"
        title="Video call"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-4 w-4 sm:h-5 sm:w-5"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"
          />
        </svg>
      </button>
    </div>
    """
  end

  attr :call, :map, required: true
  attr :show, :boolean, default: false

  def incoming_call_modal(assigns) do
    ~H"""
    <div :if={@show} class="modal modal-open">
      <div class="modal-box modal-surface">
        <h3 class="font-bold text-lg">Incoming {@call.call_type} call</h3>
        <div class="py-4">
          <div class="flex items-center gap-4">
            <.user_avatar user={@call.caller} size="lg" />
            <div>
              <p class="font-semibold">{@call.caller.username}</p>
              <p class="text-sm opacity-70">is calling you...</p>
            </div>
          </div>
        </div>

        <div class="modal-action">
          <button
            type="button"
            phx-click="reject_call"
            phx-value-call_id={@call.id}
            class="btn btn-secondary"
          >
            Decline
          </button>
          <button
            type="button"
            phx-click="answer_call"
            phx-value-call_id={@call.id}
            class="btn btn-success"
          >
            Answer
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :call, :map, required: true
  attr :show, :boolean, default: false
  attr :audio_enabled, :boolean, default: true
  attr :video_enabled, :boolean, default: true
  attr :is_caller, :boolean, default: false
  attr :call_status, :string, default: "connecting"

  def active_call_overlay(assigns) do
    ~H"""
    <div :if={@show} id="call-overlay" phx-hook="VideoDisplay" class="fixed inset-0 z-50 bg-base-300">
      <div :if={@call.call_type == "video"} class="relative h-full w-full">
        <video id="remote-video" class="h-full w-full object-cover" autoplay playsinline></video>
        <div class="absolute top-4 right-4 w-48 h-36 bg-base-200 rounded-lg overflow-hidden shadow-lg">
          <video id="local-video" class="h-full w-full object-cover" autoplay playsinline muted>
          </video>
        </div>
        <div class="absolute top-4 left-4 bg-base-200/80 rounded-lg px-4 py-2 border border-base-300/70">
          <div class="flex items-center gap-3">
            <.user_avatar user={if @is_caller, do: @call.callee, else: @call.caller} size="sm" />
            <div>
              <p class="font-semibold text-sm">
                {if @is_caller, do: @call.callee.username, else: @call.caller.username}
              </p>
              <p
                class="text-xs opacity-70"
                id="call-duration"
                phx-hook="CallTimer"
                data-status={@call_status}
              >
                {if @call_status == "connected", do: "00:00", else: "Connecting..."}
              </p>
            </div>
          </div>
        </div>
      </div>

      <div
        :if={@call.call_type == "audio"}
        class="relative h-full w-full flex items-center justify-center"
      >
        <audio id="remote-audio" autoplay></audio>
        <div class="flex flex-col items-center gap-6">
          <.user_avatar user={if @is_caller, do: @call.callee, else: @call.caller} size="2xl" />
          <div class="text-center">
            <p class="text-2xl font-semibold">
              {if @is_caller, do: @call.callee.username, else: @call.caller.username}
            </p>
            <p
              class="text-lg opacity-70 mt-2"
              id="call-duration-audio"
              phx-hook="CallTimer"
              data-status={@call_status}
            >
              {if @call_status == "connected", do: "00:00", else: "Connecting..."}
            </p>
          </div>
          <div class="flex items-center gap-2 text-sm opacity-60">
            <.spinner :if={@call_status == "connecting"} size="sm" />
            <span
              :if={@call_status == "connected"}
              class="w-2 h-2 bg-success rounded-full animate-pulse"
            >
            </span>
            <span>{String.capitalize(@call_status)}</span>
          </div>
        </div>
      </div>

      <div
        :if={@call.call_type == "video" && @call_status != "connected"}
        class="absolute top-20 left-4 bg-base-200/80 rounded-lg px-3 py-2 border border-base-300/70"
      >
        <div class="flex items-center gap-2 text-sm">
          <.spinner size="sm" />
          <span>{String.capitalize(@call_status)}...</span>
        </div>
      </div>

      <div
        :if={@call.call_type == "video" && @call_status == "connected"}
        class="absolute top-20 left-4 bg-success/15 rounded-lg px-3 py-2 border border-success/30"
      >
        <div class="flex items-center gap-2 text-sm text-success">
          <span class="w-2 h-2 bg-success rounded-full animate-pulse"></span>
          <span>Connected</span>
        </div>
      </div>

      <div
        id="call-controls"
        phx-hook="CallControls"
        class="absolute bottom-8 left-1/2 transform -translate-x-1/2"
      >
        <div class="flex gap-4 bg-base-200/80 rounded-full px-6 py-3 border border-base-300/70">
          <button
            type="button"
            data-action="toggle-audio"
            class={["btn btn-circle", if(@audio_enabled, do: "btn-ghost", else: "btn-secondary")]}
            title={if @audio_enabled, do: "Mute", else: "Unmute"}
          >
            <svg
              :if={@audio_enabled}
              xmlns="http://www.w3.org/2000/svg"
              class="h-6 w-6"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z"
              />
            </svg>
            <svg
              :if={!@audio_enabled}
              xmlns="http://www.w3.org/2000/svg"
              class="h-6 w-6"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M5.586 15H4a1 1 0 01-1-1v-4a1 1 0 011-1h1.586l4.707-4.707C10.923 3.663 12 4.109 12 5v14c0 .891-1.077 1.337-1.707.707L5.586 15z"
              />
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2"
              />
            </svg>
          </button>

          <button
            :if={@call.call_type == "video"}
            type="button"
            data-action="toggle-video"
            class={["btn btn-circle", if(@video_enabled, do: "btn-ghost", else: "btn-secondary")]}
            title={if @video_enabled, do: "Disable video", else: "Enable video"}
          >
            <svg
              :if={@video_enabled}
              xmlns="http://www.w3.org/2000/svg"
              class="h-6 w-6"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"
              />
            </svg>
            <svg
              :if={!@video_enabled}
              xmlns="http://www.w3.org/2000/svg"
              class="h-6 w-6"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"
              />
            </svg>
          </button>

          <button
            type="button"
            data-action="end-call"
            class="btn btn-circle btn-secondary"
            title="End call"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-6 w-6"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M16 8l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2M5 3a2 2 0 00-2 2v1c0 8.284 6.716 15 15 15h1a2 2 0 002-2v-3.28a1 1 0 00-.684-.948l-4.493-1.498a1 1 0 00-1.21.502l-1.13 2.257a11.042 11.042 0 01-5.516-5.517l2.257-1.128a1 1 0 00.502-1.21L9.228 3.683A1 1 0 008.279 3H5z"
              />
            </svg>
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :user, :map, required: true
  attr :size, :string, default: "md"

  defp user_avatar(assigns) do
    size_classes = %{
      "sm" => "w-8 h-8",
      "md" => "w-12 h-12",
      "lg" => "w-16 h-16",
      "2xl" => "w-24 h-24"
    }

    assigns =
      assign(assigns, :size_class, Map.get(size_classes, assigns.size, size_classes["md"]))

    ~H"""
    <div class={["avatar", if(@user.avatar, do: "", else: "placeholder")]}>
      <div class={"rounded-full #{@size_class}"}>
        <img :if={@user.avatar} src={Elektrine.Uploads.avatar_url(@user.avatar)} />
        <span :if={!@user.avatar} class="text-lg">
          {String.first(@user.username) |> String.upcase()}
        </span>
      </div>
    </div>
    """
  end

  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]
  attr :class, :string, default: nil

  defp spinner(assigns) do
    ~H"""
    <svg
      class={[
        "animate-spin",
        case @size do
          "xs" -> "w-3 h-3"
          "sm" -> "w-4 h-4"
          "lg" -> "w-8 h-8"
          _ -> "w-6 h-6"
        end,
        @class
      ]}
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
