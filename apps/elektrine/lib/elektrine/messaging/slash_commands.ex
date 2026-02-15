defmodule Elektrine.Messaging.SlashCommands do
  @moduledoc """
  Parses and resolves chat slash commands.
  """

  alias Elektrine.Giphy

  @type result :: {:send, String.t()} | {:noop, String.t()} | {:error, String.t()}

  @spec process(String.t(), keyword()) :: result
  def process(input, opts \\ []) when is_binary(input) do
    trimmed = String.trim(input)

    if trimmed == "" or not String.starts_with?(trimmed, "/") do
      {:send, trimmed}
    else
      execute(trimmed, opts)
    end
  end

  defp execute(trimmed, opts) do
    parts = String.split(trimmed, ~r/\s+/, trim: true)
    command = parts |> List.first() |> String.downcase()
    arg_text = String.replace_prefix(trimmed, List.first(parts) || "", "") |> String.trim()

    case command do
      "/help" ->
        {:noop,
         "Commands: /help, /me <action>, /shrug [text], /tableflip [text], /unflip [text], /giphy <query>, /invite"}

      "/me" ->
        format_me(arg_text, opts)

      "/shrug" ->
        {:send, append_tail(arg_text, "¯\\_(ツ)_/¯")}

      "/tableflip" ->
        {:send, append_tail(arg_text, "(╯°□°)╯︵ ┻━┻")}

      "/unflip" ->
        {:send, append_tail(arg_text, "┬─┬ ノ( ゜-゜ノ)")}

      "/giphy" ->
        resolve_giphy(arg_text, opts)

      "/invite" ->
        build_invite_link(opts)

      _ ->
        {:error, "Unknown command. Use /help to see available commands."}
    end
  end

  defp format_me("", _opts), do: {:error, "Usage: /me <action>"}

  defp format_me(action, opts) do
    actor =
      opts[:user_display] ||
        opts[:user_handle] ||
        opts[:username] ||
        "someone"

    {:send, "*#{actor} #{action}*"}
  end

  defp append_tail("", suffix), do: suffix
  defp append_tail(prefix, suffix), do: "#{prefix} #{suffix}"

  defp resolve_giphy("", _opts), do: {:error, "Usage: /giphy <search terms>"}

  defp resolve_giphy(query, opts) do
    giphy_search_fun = opts[:giphy_search_fun] || (&Giphy.search_gifs/2)

    case giphy_search_fun.(query, limit: 1) do
      {:ok, [%{url: url} | _]} when is_binary(url) and url != "" ->
        {:send, url}

      {:ok, _} ->
        {:noop, "No GIFs found for \"#{query}\"."}

      {:error, _} ->
        {:error, "Unable to fetch GIFs right now. Try again in a bit."}
    end
  end

  defp build_invite_link(opts) do
    conversation = opts[:conversation]
    endpoint_url = opts[:endpoint_url]

    cond do
      is_nil(conversation) ->
        {:error, "No active conversation to share."}

      not is_binary(endpoint_url) or endpoint_url == "" ->
        {:error, "Invite link is unavailable right now."}

      true ->
        identifier = conversation.hash || conversation.id
        {:send, "#{endpoint_url}/chat/join/#{identifier}"}
    end
  end
end
