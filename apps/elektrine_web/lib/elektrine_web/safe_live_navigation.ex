defmodule ElektrineWeb.SafeLiveNavigation do
  @moduledoc false

  import Phoenix.LiveView, only: [push_navigate: 2, redirect: 2, put_flash: 3]

  alias Elektrine.Security.SafeExternalURL

  @type option :: {:invalid_message, String.t() | nil} | {:invalid_path, String.t() | nil}

  @spec navigate(Phoenix.LiveView.Socket.t(), term(), [option()]) :: Phoenix.LiveView.Socket.t()
  def navigate(socket, url, opts \\ []) do
    case destination(url) do
      {:internal, path} ->
        push_navigate(socket, to: path)

      {:external, safe_url} ->
        redirect(socket, external: safe_url)

      {:error, _reason} ->
        handle_invalid(socket, opts)
    end
  end

  @spec noreply(Phoenix.LiveView.Socket.t(), term(), [option()]) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def noreply(socket, url, opts \\ []) do
    {:noreply, navigate(socket, url, opts)}
  end

  @spec destination(term()) ::
          {:internal, String.t()} | {:external, String.t()} | {:error, atom()}
  def destination(url) when is_binary(url) do
    normalized = String.trim(url)

    cond do
      normalized == "" ->
        {:error, :empty_url}

      control_chars?(normalized) ->
        {:error, :invalid_url}

      internal_path?(normalized) ->
        {:internal, normalized}

      true ->
        case SafeExternalURL.normalize(normalized) do
          {:ok, safe_url} -> {:external, safe_url}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def destination(_), do: {:error, :invalid_url}

  defp internal_path?("//" <> _), do: false

  defp internal_path?("/" <> _ = path) do
    case URI.parse(path) do
      %URI{scheme: nil, host: nil} -> true
      _ -> false
    end
  end

  defp internal_path?(_), do: false

  defp control_chars?(value), do: Regex.match?(~r/[\x00-\x1F\x7F]/, value)

  defp handle_invalid(socket, opts) do
    socket =
      case Keyword.get(opts, :invalid_message, "Invalid navigation URL") do
        message when is_binary(message) and message != "" -> put_flash(socket, :error, message)
        _ -> socket
      end

    case Keyword.get(opts, :invalid_path) do
      path when is_binary(path) and path != "" -> push_navigate(socket, to: path)
      _ -> socket
    end
  end
end
