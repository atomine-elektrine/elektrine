defmodule ElektrineWeb.Components.Social.RemotePostShared do
  @moduledoc """
  Shared rendering primitives for remote post list/detail views.
  """
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]
  import ElektrineWeb.CoreComponents
  import ElektrineWeb.HtmlHelpers

  attr :quoted_message, :map, required: true
  attr :variant, :atom, default: :detail, values: [:detail, :compact]
  attr :content_mode, :atom, default: :local, values: [:local, :remote_bio, :remote_post]
  attr :domain, :string, default: nil

  def quote_preview(assigns) do
    assigns =
      assigns
      |> assign(:quote_author, quoted_author(assigns.quoted_message))
      |> assign(
        :quote_content,
        quoted_content(assigns.quoted_message, assigns.content_mode, assigns.domain)
      )

    ~H"""
    <div class={
      if @variant == :compact,
        do: "mb-3 p-2 rounded border border-base-300 bg-base-100/60",
        else: "mb-4 p-3 rounded-lg border border-base-300 bg-base-200/40"
    }>
      <div class="text-xs opacity-70 mb-1">
        <.icon name="hero-chat-bubble-oval-left-ellipsis" class="w-3 h-3 inline" />
        {@quote_author}
      </div>
      <%= if @quote_content && @quote_content != "" do %>
        <div class={quote_content_class(@variant, @content_mode)}>
          {raw(@quote_content)}
        </div>
      <% else %>
        <div class={if @variant == :compact, do: "text-xs opacity-60", else: "text-sm opacity-60"}>
          Quoted post
        </div>
      <% end %>
    </div>
    """
  end

  attr :urls, :list, required: true
  attr :post_id, :string, default: nil
  attr :layout, :atom, default: :auto, values: [:auto, :single]
  attr :wrapper_class, :string, default: "mb-4"
  attr :button_class, :string, default: "image-zoom-trigger rounded-lg overflow-hidden"
  attr :image_class, :string, default: "w-full h-auto object-cover max-h-96"

  def media_gallery(assigns) do
    grid_class =
      case assigns.layout do
        :single ->
          "grid grid-cols-1 gap-2"

        _ ->
          case length(assigns.urls) do
            1 -> "grid grid-cols-1 gap-2"
            2 -> "grid grid-cols-2 gap-2"
            _ -> "grid grid-cols-2 md:grid-cols-3 gap-2"
          end
      end

    assigns = assign(assigns, :grid_class, grid_class)

    ~H"""
    <div class={[@grid_class, @wrapper_class]}>
      <%= for {url, idx} <- Enum.with_index(@urls) do %>
        <button
          type="button"
          phx-click="open_image_modal"
          phx-value-url={url}
          phx-value-images={Jason.encode!(@urls)}
          phx-value-index={idx}
          {@post_id && [{"phx-value-post_id", @post_id}] || []}
          class={@button_class}
        >
          <img
            src={url}
            alt=""
            class={@image_class}
            loading="lazy"
          />
        </button>
      <% end %>
    </div>
    """
  end

  attr :content, :string, default: ""
  attr :textarea_name, :string, default: "content"
  attr :textarea_id, :string, default: nil
  attr :placeholder, :string, default: "Write your reply..."
  attr :textarea_class, :string, default: "textarea textarea-bordered w-full"
  attr :rows, :integer, default: 3
  attr :on_submit, :string, default: "submit_reply"
  attr :on_change, :string, default: nil
  attr :on_cancel, :string, required: true
  attr :cancel_class, :string, default: "btn btn-ghost btn-sm"
  attr :submit_class, :string, default: "btn btn-secondary btn-sm"
  attr :cancel_label, :string, default: "Cancel"
  attr :submit_label, :string, default: "Reply"
  attr :submit_icon, :string, default: nil
  attr :submit_icon_class, :string, default: "w-4 h-4 mr-1"
  attr :submit_disable_with, :string, default: "Posting..."
  attr :wrapper_class, :string, default: "mt-4 pt-4 border-t border-base-300"
  attr :form_class, :string, default: "space-y-2"
  attr :click_stop, :boolean, default: false
  attr :textarea_debounce, :string, default: nil
  attr :textarea_hook, :string, default: nil
  attr :required, :boolean, default: true

  def inline_reply_form(assigns) do
    ~H"""
    <div class={@wrapper_class} phx-click={@click_stop && "stop_propagation"}>
      <.form for={%{}} phx-submit={@on_submit} class={@form_class}>
        <textarea
          id={@textarea_id}
          name={@textarea_name}
          placeholder={@placeholder}
          class={@textarea_class}
          rows={@rows}
          phx-change={@on_change}
          phx-debounce={@textarea_debounce}
          phx-hook={@textarea_hook}
          required={@required}
        ><%= @content %></textarea>
        <div class="flex gap-2 justify-end">
          <button
            type="button"
            phx-click={@on_cancel}
            class={@cancel_class}
          >
            {@cancel_label}
          </button>
          <button
            type="submit"
            class={@submit_class}
            phx-disable-with={@submit_disable_with}
          >
            <%= if @submit_icon do %>
              <.icon name={@submit_icon} class={@submit_icon_class} />
            <% end %>
            {@submit_label}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  defp quoted_author(quoted_message) do
    cond do
      Ecto.assoc_loaded?(quoted_message.remote_actor) && quoted_message.remote_actor ->
        "@#{quoted_message.remote_actor.username}@#{quoted_message.remote_actor.domain}"

      Ecto.assoc_loaded?(quoted_message.sender) && quoted_message.sender ->
        "@#{quoted_message.sender.handle || quoted_message.sender.username}"

      true ->
        "Quoted post"
    end
  end

  defp quoted_content(quoted_message, _mode, _domain)
       when is_nil(quoted_message.content) or quoted_message.content == "",
       do: nil

  defp quoted_content(quoted_message, :local, _domain) do
    quoted_message.content
    |> make_content_safe_with_links()
    |> preserve_line_breaks()
  end

  defp quoted_content(quoted_message, :remote_bio, domain) do
    render_remote_bio(quoted_message.content, domain)
  end

  defp quoted_content(quoted_message, :remote_post, domain) do
    render_remote_post_content(quoted_message.content, domain)
  end

  defp quote_content_class(:compact, _mode), do: "text-xs line-clamp-2 break-words opacity-80"
  defp quote_content_class(:detail, :local), do: "text-sm line-clamp-4 break-words"
  defp quote_content_class(:detail, _mode), do: "text-sm line-clamp-5 break-words"
end
