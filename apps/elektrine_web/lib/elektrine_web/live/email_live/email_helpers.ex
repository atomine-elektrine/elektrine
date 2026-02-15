defmodule ElektrineWeb.EmailLive.EmailHelpers do
  @moduledoc """
  Helper functions for working with emails in the LiveView components.
  """
  use Phoenix.Component
  import ElektrineWeb.CoreComponents

  # Translation
  use Gettext, backend: ElektrineWeb.Gettext

  # Routes generation with the ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router,
    statics: ElektrineWeb.static_paths()

  def format_date(datetime) do
    case datetime do
      %DateTime{} ->
        Calendar.strftime(datetime, "%b %d, %Y %H:%M")

      _ ->
        ""
    end
  end

  def format_datetime(datetime) do
    case datetime do
      %DateTime{} ->
        Calendar.strftime(datetime, "%b %d, %Y at %I:%M %p")

      _ ->
        ""
    end
  end

  @doc """
  Formats reply_later_at as relative time (e.g., "in 2 days", "tomorrow", "overdue")
  """
  def format_reply_later_relative(datetime) do
    case datetime do
      %DateTime{} ->
        now = DateTime.utc_now()
        diff_seconds = DateTime.diff(datetime, now)
        diff_days = div(diff_seconds, 86400)
        diff_hours = div(diff_seconds, 3600)

        cond do
          diff_seconds < 0 ->
            gettext("Overdue")

          diff_hours < 1 ->
            gettext("Within an hour")

          diff_hours < 24 ->
            gettext("Today")

          diff_days == 1 ->
            gettext("Tomorrow")

          diff_days < 7 ->
            gettext("In %{count} days", count: diff_days)

          diff_days < 14 ->
            gettext("Next week")

          diff_days < 30 ->
            gettext("In %{count} weeks", count: div(diff_days, 7))

          true ->
            gettext("In %{count} months", count: div(diff_days, 30))
        end

      _ ->
        ""
    end
  end

  @doc """
  Returns badge color class based on reply_later urgency
  """
  def reply_later_urgency_class(datetime) do
    case datetime do
      %DateTime{} ->
        now = DateTime.utc_now()
        diff_seconds = DateTime.diff(datetime, now)
        diff_hours = div(diff_seconds, 3600)

        cond do
          diff_seconds < 0 -> "badge-error animate-pulse"
          diff_hours < 24 -> "badge-secondary"
          true -> "badge-info"
        end

      _ ->
        "badge-ghost"
    end
  end

  def is_overdue?(datetime) do
    case datetime do
      %DateTime{} ->
        DateTime.diff(datetime, DateTime.utc_now()) < 0

      _ ->
        false
    end
  end

  def truncate(text, max_length \\ 50), do: Elektrine.TextHelpers.truncate(text, max_length)

  @doc """
  Generate a clean preview from email content, handling HTML and base64 encoding
  """
  def email_preview(message, max_length \\ 150) do
    # Get plain text content
    content =
      cond do
        message.text_body && String.trim(message.text_body) != "" ->
          message.text_body
          # Decode quoted-printable encoding first
          |> decode_body()
          # Remove image URLs in square brackets like [https://...]
          |> String.replace(~r/\[https?:\/\/[^\]]+\]/i, "")
          # Remove bare URLs
          |> String.replace(~r/https?:\/\/\S+/i, "")
          # Strip any HTML tags that might be in plain text
          |> String.replace(~r/<[^>]+>/, " ")
          |> decode_all_html_entities()

        message.html_body && String.trim(message.html_body) != "" ->
          # Simple HTML to text conversion
          message.html_body
          # Decode quoted-printable encoding first
          |> decode_body()
          # Remove script and style blocks entirely (with proper multiline matching)
          |> String.replace(~r/<script\b[^>]*>.*?<\/script>/ims, "")
          |> String.replace(~r/<style\b[^>]*>.*?<\/style>/ims, "")
          # Also remove any CSS that might be at the start (common in email templates)
          |> String.replace(~r/^[\s]*[a-z\s,#\.]+\{[^}]*\}/m, "")
          # Remove image tags and their alt text
          |> String.replace(~r/<img[^>]*>/i, "")
          # Remove links but keep link text
          |> String.replace(~r/<a[^>]*>/i, "")
          |> String.replace(~r/<\/a>/i, " ")
          # Remove all other HTML tags
          |> String.replace(~r/<[^>]+>/, " ")
          # Remove URLs that might be left in the text
          |> String.replace(~r/https?:\/\/\S+/i, "")
          |> decode_all_html_entities()

        true ->
          "(No content available)"
      end

    content
    |> ensure_valid_utf8()
    # Remove any remaining CSS-like patterns (rules with curly braces)
    |> String.replace(~r/[a-z\-]+\s*:\s*[^;}]+;/i, "")
    |> String.replace(~r/\{[^}]*\}/m, " ")
    # Collapse multiple spaces
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    # Skip leading content that looks like CSS comments or directives
    |> String.replace(~r/^\/\*.*?\*\//m, "")
    |> String.trim()
    |> truncate(max_length)
  end

  defp ensure_valid_utf8(text) do
    if String.valid?(text) do
      text
    else
      # Force to valid UTF-8
      case :unicode.characters_to_binary(text, :utf8, :utf8) do
        {:error, _, _} ->
          # Fallback: keep only ASCII
          text
          |> :binary.bin_to_list()
          |> Enum.filter(fn byte -> byte >= 32 and byte <= 126 end)
          |> :binary.list_to_bin()

        {:incomplete, good, _bad} ->
          good

        good when is_binary(good) ->
          good
      end
    end
  end

  defp decode_all_html_entities(text) do
    text
    # Common named entities
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&mdash;", "—")
    |> String.replace("&ndash;", "-")
    |> String.replace("&hellip;", "...")
    |> String.replace("&copy;", "©")
    |> String.replace("&reg;", "®")
    |> String.replace("&trade;", "™")
    |> String.replace("&ldquo;", "\"")
    |> String.replace("&rdquo;", "\"")
    |> String.replace("&lsquo;", "'")
    |> String.replace("&rsquo;", "'")
    # Numeric entities
    |> String.replace(~r/&#(\d+);/, fn full_match ->
      case Regex.run(~r/&#(\d+);/, full_match) do
        [_, num] ->
          case Integer.parse(num) do
            # Remove problematic combining mark
            {code, ""} when code == 847 ->
              ""

            {code, ""} when code >= 32 and code <= 126 ->
              try do
                <<code::utf8>>
              rescue
                _ -> " "
              end

            _ ->
              " "
          end

        _ ->
          full_match
      end
    end)
    # Hex entities
    |> String.replace(~r/&#x([0-9a-fA-F]+);/, fn full_match ->
      case Regex.run(~r/&#x([0-9a-fA-F]+);/, full_match) do
        [_, hex] ->
          case Integer.parse(hex, 16) do
            # Remove problematic combining mark
            {code, ""} when code == 0x034F ->
              ""

            {code, ""} when code >= 32 and code <= 126 ->
              try do
                <<code::utf8>>
              rescue
                _ -> " "
              end

            _ ->
              " "
          end

        _ ->
          full_match
      end
    end)
  end

  def message_class(message) do
    if message.read do
      "bg-base-200 border-base-300"
    else
      "bg-gradient-to-r from-primary/5 to-primary/10 border-primary/20 shadow-sm"
    end
  end

  attr :mailbox, :map, required: true
  attr :storage_info, :map, required: false
  attr :unread_count, :integer, required: true
  attr :current_page, :string, required: true
  attr :current_user, :map, required: true
  attr :custom_folders, :list, default: []
  attr :current_folder_id, :integer, default: nil

  def sidebar(assigns) do
    # Use storage_info from assigns (updated via PubSub broadcasts)
    # Don't fetch from DB on every render - that's inefficient and ignores real-time updates
    # Ensure custom_folders has a default value
    assigns = assign_new(assigns, :custom_folders, fn -> [] end)
    assigns = assign_new(assigns, :current_folder_id, fn -> nil end)

    ~H"""
    <!-- Sidebar -->
    <div class="w-full lg:w-72 xl:w-80 lg:sticky lg:top-[9rem] lg:self-start flex-shrink-0">
      <!-- Mailbox Info Card -->
      <div
        id={"mailbox-info-card-#{@mailbox.id}"}
        phx-hook="GlassCard"
        class="card glass-card shadow-lg mb-6 rounded-box"
      >
        <div class="card-body p-6">
          <div class="flex-1 min-w-0">
            <h2 class="font-bold text-lg">{gettext("Your Mailbox")}</h2>
            <div class="space-y-1">
              <div class="flex items-center gap-2">
                <p
                  class="text-sm text-base-content/70 font-mono truncate flex-1"
                  title={@mailbox.email}
                >
                  {@mailbox.email}
                </p>
                <button
                  id={"copy-email-primary-#{@mailbox.id}"}
                  type="button"
                  phx-hook="CopyEmail"
                  data-email={@mailbox.email}
                  class="btn btn-ghost btn-xs flex-shrink-0"
                  title={gettext("Copy to clipboard")}
                >
                  <.icon name="hero-clipboard-document" class="w-3 h-3" />
                </button>
              </div>
              <div class="flex items-center gap-2">
                <p
                  class="text-xs text-base-content/50 font-mono truncate flex-1"
                  title={String.replace(@mailbox.email, "@elektrine.com", "@z.org")}
                >
                  {String.replace(@mailbox.email, "@elektrine.com", "@z.org")}
                </p>
                <button
                  id={"copy-email-alternate-#{@mailbox.id}"}
                  type="button"
                  phx-hook="CopyEmail"
                  data-email={String.replace(@mailbox.email, "@elektrine.com", "@z.org")}
                  class="btn btn-ghost btn-xs flex-shrink-0"
                  title={gettext("Copy to clipboard")}
                >
                  <.icon name="hero-clipboard-document" class="w-3 h-3" />
                </button>
              </div>
              
    <!-- Storage Usage Display - Hidden on smaller screens -->
              <%= if @storage_info do %>
                <div class="hidden xl:block mt-3 pt-3 border-t border-base-300/50">
                  <div class="flex items-center justify-between text-xs text-base-content/70 mb-1">
                    <span class="font-medium">{gettext("Storage Used")}</span>
                    <span class={
                      cond do
                        @storage_info.over_limit -> "text-red-800 font-semibold"
                        @storage_info.percentage > 0.8 -> "text-orange-500 font-medium"
                        true -> "text-base-content/60"
                      end
                    }>
                      {@storage_info.used_formatted} / {@storage_info.limit_formatted}
                    </span>
                  </div>

                  <div class="flex items-center space-x-3">
                    <div class="flex-1 min-w-0">
                      <div class="w-full h-2 bg-base-300/50 rounded-full overflow-hidden shadow-inner">
                        <div
                          class={
                            cond do
                              @storage_info.over_limit ->
                                "h-full bg-gradient-to-r from-red-700 to-red-800 transition-all duration-300"

                              @storage_info.percentage > 0.8 ->
                                "h-full bg-gradient-to-r from-orange-400 to-orange-500 transition-all duration-300"

                              true ->
                                "h-full bg-gradient-to-r from-primary to-primary transition-all duration-300"
                            end
                          }
                          style={"width: #{min(@storage_info.percentage * 100, 100)}%"}
                        />
                      </div>
                    </div>
                    <span class={
                      cond do
                        @storage_info.over_limit -> "text-red-800 font-semibold text-xs"
                        @storage_info.percentage > 0.8 -> "text-orange-500 font-medium text-xs"
                        true -> "text-base-content/60 text-xs"
                      end
                    }>
                      {Float.round(@storage_info.percentage * 100, 1)}%
                    </span>
                  </div>

                  <%= cond do %>
                    <% @storage_info.over_limit -> %>
                      <div class="mt-2 text-xs text-red-800 font-medium flex items-center">
                        <.icon name="hero-exclamation-triangle" class="h-3 w-3 mr-1" />
                        {gettext("Storage limit exceeded")}
                      </div>
                    <% @storage_info.percentage > 0.8 -> %>
                      <div class="mt-2 text-xs text-orange-500 font-medium flex items-center">
                        <.icon name="hero-exclamation-triangle" class="h-3 w-3 mr-1" />
                        {gettext("Storage nearly full")}
                      </div>
                    <% true -> %>
                      <!-- No warning needed -->
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Navigation Menu -->
      <div
        id={"nav-menu-card-#{@mailbox.id}"}
        phx-hook="GlassCard"
        class="card glass-card shadow-lg rounded-box"
      >
        <div class="card-body p-3">
          <ul class="menu menu-lg rounded-box w-full">
            <li>
              <a
                href={~p"/email?tab=inbox"}
                data-phx-link="patch"
                data-phx-link-state="push"
                class={
                  if(@current_page == "inbox",
                    do: "bg-orange-500/10 text-orange-500 font-semibold rounded-lg",
                    else: "text-base-content hover:bg-orange-500/5 hover:text-orange-500"
                  )
                }
              >
                <.icon name="hero-inbox" class="h-5 w-5" /> {gettext("Inbox")}
                <%= if @unread_count > 0 do %>
                  <div class="badge badge-sm badge-secondary animate-pulse">
                    {@unread_count}
                  </div>
                <% end %>
              </a>
            </li>
            <li>
              <a
                href={~p"/email?tab=sent"}
                data-phx-link="patch"
                data-phx-link-state="push"
                class={
                  if(@current_page == "sent",
                    do: "bg-orange-500/10 text-orange-500 font-semibold rounded-lg",
                    else: "text-base-content hover:bg-orange-500/5 hover:text-orange-500"
                  )
                }
              >
                <.icon name="hero-paper-airplane" class="h-5 w-5" /> {gettext("Sent")}
              </a>
            </li>
            <li>
              <a
                href={~p"/email?tab=drafts"}
                data-phx-link="patch"
                data-phx-link-state="push"
                class={
                  if(@current_page == "drafts",
                    do: "bg-orange-500/10 text-orange-500 font-semibold rounded-lg",
                    else: "text-base-content hover:bg-orange-500/5 hover:text-orange-500"
                  )
                }
              >
                <.icon name="hero-document" class="h-5 w-5" /> {gettext("Drafts")}
              </a>
            </li>
            <li>
              <a
                href={~p"/email?tab=search"}
                data-phx-link="patch"
                data-phx-link-state="push"
                class={
                  if(@current_page == "search",
                    do: "bg-orange-500/10 text-orange-500 font-semibold rounded-lg",
                    else: "text-base-content hover:bg-orange-500/5 hover:text-orange-500"
                  )
                }
              >
                <.icon name="hero-magnifying-glass" class="h-5 w-5" /> {gettext("Search")}
              </a>
            </li>
            <li>
              <a
                href={~p"/email?tab=spam"}
                data-phx-link="patch"
                data-phx-link-state="push"
                class={
                  if(@current_page == "spam",
                    do: "bg-orange-500/10 text-orange-500 font-semibold rounded-lg",
                    else: "text-base-content hover:bg-orange-500/5 hover:text-orange-500"
                  )
                }
              >
                <.icon name="hero-exclamation-triangle" class="h-5 w-5" /> {gettext("Spam")}
              </a>
            </li>
            <li>
              <a
                href={~p"/email?tab=trash"}
                data-phx-link="patch"
                data-phx-link-state="push"
                class={
                  if(@current_page == "trash",
                    do: "bg-orange-500/10 text-orange-500 font-semibold rounded-lg",
                    else: "text-base-content hover:bg-orange-500/5 hover:text-orange-500"
                  )
                }
              >
                <.icon name="hero-trash" class="h-5 w-5" /> {gettext("Trash")}
              </a>
            </li>
            <li>
              <a
                href={~p"/email?tab=archive"}
                data-phx-link="patch"
                data-phx-link-state="push"
                class={
                  if(@current_page == "archive",
                    do: "bg-orange-500/10 text-orange-500 font-semibold rounded-lg",
                    else: "text-base-content hover:bg-orange-500/5 hover:text-orange-500"
                  )
                }
              >
                <.icon name="hero-archive-box" class="h-5 w-5" /> {gettext("Archive")}
              </a>
            </li>

            <li>
              <a
                href={~p"/email?tab=contacts"}
                data-phx-link="patch"
                data-phx-link-state="push"
                class={
                  if(@current_page == "contacts",
                    do: "bg-orange-500/10 text-orange-500 font-semibold rounded-lg",
                    else: "text-base-content hover:bg-orange-500/5 hover:text-orange-500"
                  )
                }
              >
                <.icon name="hero-user-group" class="h-5 w-5" /> {gettext("Contacts")}
              </a>
            </li>
            <li>
              <a
                href={~p"/email?tab=calendar"}
                data-phx-link="patch"
                data-phx-link-state="push"
                class={
                  if(@current_page == "calendar",
                    do: "bg-orange-500/10 text-orange-500 font-semibold rounded-lg",
                    else: "text-base-content hover:bg-orange-500/5 hover:text-orange-500"
                  )
                }
              >
                <.icon name="hero-calendar" class="h-5 w-5" /> {gettext("Calendar")}
              </a>
            </li>
            <li>
              <.link
                navigate={~p"/email/settings"}
                class={
                  if @current_page == "settings",
                    do: "bg-orange-500/10 text-orange-500 font-semibold rounded-lg",
                    else: "text-base-content hover:bg-orange-500/5 hover:text-orange-500"
                }
              >
                <.icon name="hero-cog-6-tooth" class="h-5 w-5" /> {gettext("Settings")}
              </.link>
            </li>
            
    <!-- Custom Folders -->
            <%= if length(@custom_folders) > 0 do %>
              <li class="menu-title pt-4 pb-1">
                <span class="text-xs uppercase tracking-wide text-base-content/50">
                  {gettext("Folders")}
                </span>
              </li>
              <%= for folder <- @custom_folders do %>
                <% is_active = @current_page == "folder" && @current_folder_id == folder.id %>
                <li>
                  <a
                    href={~p"/email?tab=folder&folder_id=#{folder.id}"}
                    data-phx-link="patch"
                    data-phx-link-state="push"
                    class={
                      if(is_active,
                        do: "bg-orange-500/10 text-orange-500 font-semibold rounded-lg",
                        else: "text-base-content hover:bg-orange-500/5 hover:text-orange-500"
                      )
                    }
                  >
                    <div class="flex items-center gap-2">
                      <span
                        class="w-2.5 h-2.5 rounded-full flex-shrink-0"
                        style={"background-color: #{folder.color || "#3b82f6"}"}
                      />
                      <.icon
                        name="hero-folder"
                        class={["h-5 w-5", !is_active && "text-base-content/70"]}
                      />
                    </div>
                    <span class="truncate">{folder.name}</span>
                  </a>
                </li>
              <% end %>
            <% end %>
          </ul>
          
    <!-- Compose Button - Separate from menu -->
          <div class="mt-4">
            <.link
              navigate={~p"/email/compose?return_to=#{@current_page}"}
              class="btn btn-primary w-full gap-2 flex items-center justify-center"
            >
              <.icon name="hero-pencil-square" class="h-5 w-5" /> {gettext("Compose")}
            </.link>
          </div>
          
    <!-- Keyboard Shortcuts Button -->
          <div class="mt-2">
            <button
              class="btn btn-ghost btn-sm w-full gap-2 flex items-center justify-center text-base-content/70 hover:text-base-content"
              phx-click="show_keyboard_shortcuts"
              title={gettext("Keyboard shortcuts (Shift + /)")}
            >
              <.icon name="hero-command-line" class="h-4 w-4" /> {gettext("Shortcuts")}
              <kbd class="kbd kbd-xs ml-1">?</kbd>
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Returns an appropriate icon name for a file type based on content type
  """
  def get_file_icon(content_type) when is_binary(content_type) do
    case String.downcase(content_type) do
      "image/" <> _ -> "hero-photo"
      "video/" <> _ -> "hero-play"
      "audio/" <> _ -> "hero-musical-note"
      "text/" <> _ -> "hero-document-text"
      "application/pdf" -> "hero-document"
      "application/zip" <> _ -> "hero-archive-box"
      "application/x-" <> _ -> "hero-archive-box"
      _ -> "hero-document"
    end
  end

  def get_file_icon(_), do: "hero-document"

  @doc """
  Formats file size in human readable format
  """
  def format_file_size(size) when is_integer(size) do
    cond do
      size >= 1024 * 1024 * 1024 -> "#{Float.round(size / (1024 * 1024 * 1024), 1)} GB"
      size >= 1024 * 1024 -> "#{Float.round(size / (1024 * 1024), 1)} MB"
      size >= 1024 -> "#{Float.round(size / 1024, 1)} KB"
      true -> "#{size} B"
    end
  end

  def format_file_size(_), do: "0 B"

  @doc """
  Extracts sender name from email address
  """
  def get_sender_name(from) when is_binary(from) do
    case Regex.run(~r/^(.+?)\s*<(.+)>$/, from) do
      [_, name, _email] -> String.trim(name, "\"")
      _ -> from
    end
  end

  def get_sender_name(_), do: "Unknown"

  @doc """
  Gets sender initials for avatar display
  """
  def get_sender_initials(from) when is_binary(from) do
    name = get_sender_name(from)

    case String.split(name, " ") do
      [first] ->
        String.slice(String.upcase(first), 0, 1)

      [first, last | _] ->
        String.slice(String.upcase(first), 0, 1) <> String.slice(String.upcase(last), 0, 1)

      _ ->
        "?"
    end
  end

  def get_sender_initials(_), do: "?"

  def get_recipient_initials(to) when is_binary(to) do
    # Extract email from potential format like "Name <email@example.com>"
    email_part =
      case String.split(to, "<") do
        [name, _email_part] -> String.trim(name)
        [email] -> email
      end

    # Extract name or use email username
    name_part =
      case email_part do
        "" -> String.split(to, "@") |> List.first() || ""
        name -> name
      end

    name_part
    |> String.split()
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      initials -> initials
    end
  end

  def get_recipient_initials(_), do: "?"

  @doc """
  Decode MIME-encoded headers (RFC 2047)
  Format: =?charset?encoding?encoded-text?=

  Note: The mail library doesn't include RFC 2047 header decoding,
  so we keep the custom implementation for subject/header decoding.
  """
  def decode_subject(nil), do: nil
  def decode_subject(""), do: ""

  def decode_subject(text) when is_binary(text) do
    # Remove whitespace between adjacent encoded-words (RFC 2047 section 6.2)
    text = Regex.replace(~r/\?=\s+=\?/, text, "?==?")

    case Regex.scan(~r/=\?([^?]+)\?([BQbq])\?([^?]+)\?=/, text) do
      [] ->
        # No MIME encoding, return as-is
        text

      matches ->
        # Decode each MIME-encoded segment
        Enum.reduce(matches, text, fn [full_match, _charset, encoding, encoded_text], acc ->
          decoded =
            case String.upcase(encoding) do
              "B" ->
                # Base64 encoding
                case Base.decode64(encoded_text) do
                  {:ok, decoded_bytes} -> decoded_bytes
                  :error -> full_match
                end

              "Q" ->
                # Q-encoding (similar to quoted-printable but for headers)
                encoded_text
                # Underscores represent spaces in headers
                |> String.replace("_", " ")
                |> decode_header_qencoding()

              _ ->
                full_match
            end

          String.replace(acc, full_match, decoded)
        end)
    end
  end

  # Decode Q-encoding for headers (similar to quoted-printable)
  defp decode_header_qencoding(text) do
    Regex.replace(~r/=([0-9A-Fa-f]{2})/, text, fn _, hex ->
      case Integer.parse(hex, 16) do
        {byte_value, ""} -> <<byte_value>>
        _ -> "=#{hex}"
      end
    end)
  end

  @doc """
  Decode Quoted-Printable encoding in email body text
  Uses Mail library for robust decoding
  """
  def decode_body(nil), do: nil
  def decode_body(""), do: ""

  def decode_body(text) when is_binary(text) do
    # Check if text contains quoted-printable encoding markers
    if Regex.match?(~r/=[0-9A-Fa-f]{2}|=\r?\n/, text) do
      # Use Mail library's quoted-printable decoder (returns binary directly)
      Mail.Encoders.QuotedPrintable.decode(text)
    else
      # Already decoded, return as-is
      text
    end
  end
end
