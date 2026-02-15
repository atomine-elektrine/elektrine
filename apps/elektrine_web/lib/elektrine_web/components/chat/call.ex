defmodule ElektrineWeb.Components.Chat.Call do
  use Phoenix.Component
  import ElektrineWeb.CoreComponents, only: [spinner: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router,
    statics: ElektrineWeb.static_paths()

  @doc """
  Renders call action buttons (audio and video call)
  """
  attr :user, :map, required: true
  attr :conversation_id, :string, default: nil

  def call_buttons(assigns) do
    ~H"""
    <div class="flex gap-1 sm:gap-2">
      <button
        type="button"
        phx-click="initiate_call"
        phx-value-user_id={@user.id}
        phx-value-call_type="audio"
        phx-value-conversation_id={@conversation_id}
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
        phx-value-user_id={@user.id}
        phx-value-call_type="video"
        phx-value-conversation_id={@conversation_id}
        class="btn btn-ghost btn-circle btn-sm p-0 min-h-0 h-8 w-8 sm:h-9 sm:w-9 flex-shrink-0"
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

  @doc """
  Renders incoming call notification modal
  """
  attr :call, :map, required: true
  attr :show, :boolean, default: false

  def incoming_call_modal(assigns) do
    ~H"""
    <div :if={@show} class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg">Incoming {@call.call_type} call</h3>
        <div class="py-4">
          <div class="flex items-center gap-4">
            <.user_avatar user={@call.caller} size="lg" />
            <div>
              <p class="font-semibold">{@call.caller.username}</p>
              <p class="text-sm opacity-70">
                is calling you...
              </p>
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

  @doc """
  Renders active call overlay with video streams and controls
  """
  attr :call, :map, required: true
  attr :show, :boolean, default: false
  attr :audio_enabled, :boolean, default: true
  attr :video_enabled, :boolean, default: true
  attr :is_caller, :boolean, default: false
  attr :call_status, :string, default: "connecting"

  def active_call_overlay(assigns) do
    ~H"""
    <div
      :if={@show}
      id="call-overlay"
      phx-hook="VideoDisplay"
      class="fixed inset-0 z-50 bg-base-300"
    >
      <!-- Remote video (full screen) for video calls -->
      <div :if={@call.call_type == "video"} class="relative h-full w-full">
        <video
          id="remote-video"
          class="h-full w-full object-cover"
          autoplay
          playsinline
        >
        </video>
        
    <!-- Local video (picture-in-picture) -->
        <div class="absolute top-4 right-4 w-48 h-36 bg-base-200 rounded-lg overflow-hidden shadow-lg">
          <video
            id="local-video"
            class="h-full w-full object-cover"
            autoplay
            playsinline
            muted
          >
          </video>
        </div>
        
    <!-- Call info overlay for video calls -->
        <div class="absolute top-4 left-4 bg-base-100/80 backdrop-blur rounded-lg px-4 py-2">
          <div class="flex items-center gap-3">
            <.user_avatar
              user={if @is_caller, do: @call.callee, else: @call.caller}
              size="sm"
            />
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
      
    <!-- Audio-only call UI -->
      <div
        :if={@call.call_type == "audio"}
        class="relative h-full w-full flex items-center justify-center"
      >
        <!-- Hidden audio element for remote stream -->
        <audio id="remote-audio" autoplay></audio>
        
    <!-- Centered user avatar and info -->
        <div class="flex flex-col items-center gap-6">
          <.user_avatar
            user={if @is_caller, do: @call.callee, else: @call.caller}
            size="2xl"
          />
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
          
    <!-- Connection status indicator -->
          <div class="flex items-center gap-2 text-sm opacity-60">
            <.spinner :if={@call_status == "connecting"} size="sm" variant="dots" />
            <span
              :if={@call_status == "connected"}
              class="w-2 h-2 bg-success rounded-full animate-pulse"
            >
            </span>
            <span>{String.capitalize(@call_status)}</span>
          </div>
        </div>
      </div>
      
    <!-- Video calls connection status -->
      <div
        :if={@call.call_type == "video" && @call_status != "connected"}
        class="absolute top-20 left-4 bg-base-100/80 backdrop-blur rounded-lg px-3 py-2"
      >
        <div class="flex items-center gap-2 text-sm">
          <.spinner size="sm" variant="dots" />
          <span>{String.capitalize(@call_status)}...</span>
        </div>
      </div>

      <div
        :if={@call.call_type == "video" && @call_status == "connected"}
        class="absolute top-20 left-4 bg-success/20 backdrop-blur rounded-lg px-3 py-2"
      >
        <div class="flex items-center gap-2 text-sm text-success">
          <span class="w-2 h-2 bg-success rounded-full animate-pulse"></span>
          <span>Connected</span>
        </div>
      </div>
      
    <!-- Call controls (common for audio and video) -->
      <div
        id="call-controls"
        phx-hook="CallControls"
        class="absolute bottom-8 left-1/2 transform -translate-x-1/2"
      >
        <div class="flex gap-4 bg-base-100/80 backdrop-blur rounded-full px-6 py-3">
          <!-- Mute/Unmute audio -->
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
          
    <!-- Enable/Disable video -->
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
          
    <!-- End call -->
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
end
