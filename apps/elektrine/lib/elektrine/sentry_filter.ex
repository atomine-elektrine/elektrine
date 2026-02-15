defmodule Elektrine.SentryFilter do
  @moduledoc """
  Filters out benign errors from Sentry reporting.
  """

  @doc """
  Filter function called before sending events to Sentry.
  Return the event to send it, or nil to drop it.

  Note: Sentry's `before_send` callback passes only the event (arity 1).
  """
  def filter_event(event) do
    if should_drop?(event) do
      nil
    else
      event
    end
  end

  defp should_drop?(%{original_exception: %Bandit.TransportError{message: message}})
       when is_binary(message) do
    # Client disconnected normally - not an error we need to track
    String.contains?(message, "Client reset stream normally") or
      String.contains?(message, "closed") or
      String.contains?(message, "timeout")
  end

  defp should_drop?(%{original_exception: %Mint.TransportError{}}) do
    # Mint transport errors are usually client disconnects
    true
  end

  defp should_drop?(%{original_exception: %Bandit.HTTPError{message: message}})
       when is_binary(message) do
    # Crypto mining pool scanners and other malformed requests
    String.contains?(message, "mining.subscribe") or
      String.contains?(message, "mining.authorize") or
      String.contains?(message, "Request line HTTP error")
  end

  defp should_drop?(_event), do: false
end
