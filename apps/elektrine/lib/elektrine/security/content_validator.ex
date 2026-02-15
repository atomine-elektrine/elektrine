defmodule Elektrine.Security.ContentValidator do
  @moduledoc """
  Advanced content validation and security for all contexts.
  Prevents spam, abuse, and malicious content across Chat, Timeline, and Discussions.
  """

  # Spam patterns
  @spam_patterns [
    # Excessive repeated characters
    ~r/(.)\1{10,}/,
    # Too many caps
    ~r/[A-Z]{20,}/,
    # Excessive mentions
    ~r/(@\w+.*){6,}/,
    # Suspicious links patterns
    ~r/bit\.ly|tinyurl|t\.co|goo\.gl/i,
    # Cryptocurrency spam
    ~r/bitcoin|crypto|ethereum|nft|pump.*dump/i,
    # Common spam phrases
    ~r/click.*here.*now|limited.*time.*offer|act.*now|free.*money/i
  ]

  # Malicious patterns
  @malicious_patterns [
    # XSS attempts
    ~r/<script|javascript:|on\w+\s*=/i,
    # SQL injection attempts
    ~r/union.*select|drop.*table|insert.*into/i,
    # Command injection
    ~r/\|\s*[a-z]+|&&\s*[a-z]+|;\s*[a-z]+/i,
    # Path traversal
    ~r/\.\.\/|\.\.\\|\0/,
    # Suspicious protocols
    ~r/file:|ftp:|data:|vbscript:/i
  ]

  @doc """
  Validates content for security and spam across all contexts.
  Returns {:ok, content} or {:error, reason}.
  """
  def validate_content(content, context \\ :general) when is_binary(content) do
    with :ok <- check_length(content, context),
         :ok <- check_malicious_content(content),
         :ok <- check_spam_patterns(content),
         :ok <- check_context_specific_rules(content, context) do
      {:ok, sanitize_content(content)}
    else
      error -> error
    end
  end

  @doc """
  Validates title content for discussions and timeline posts.
  """
  def validate_title(title) when is_binary(title) do
    cond do
      String.length(title) > 200 ->
        {:error, :title_too_long}

      String.trim(title) == "" ->
        {:error, :title_empty}

      Regex.match?(~r/[<>"]/, title) ->
        {:error, :title_invalid_chars}

      true ->
        {:ok, String.trim(title)}
    end
  end

  @doc """
  Checks if user behavior is suspicious.
  """
  def check_user_behavior(user_id, _action, content \\ "") do
    # Check for rapid identical content posting
    if detect_duplicate_content?(user_id, content) do
      {:error, :duplicate_content}
    else
      :ok
    end
  end

  # Private functions

  defp check_length(content, context) do
    max_length =
      case context do
        :chat -> 2000
        :timeline -> 4000
        :discussion -> 10000
        _ -> 2000
      end

    if String.length(content) > max_length do
      {:error, {:content_too_long, "Content exceeds #{max_length} character limit"}}
    else
      :ok
    end
  end

  defp check_malicious_content(content) do
    malicious_found = Enum.find(@malicious_patterns, &Regex.match?(&1, content))

    case malicious_found do
      nil -> :ok
      _pattern -> {:error, :malicious_content}
    end
  end

  defp check_spam_patterns(content) do
    spam_found = Enum.find(@spam_patterns, &Regex.match?(&1, content))

    case spam_found do
      nil -> :ok
      _pattern -> {:error, :spam_detected}
    end
  end

  defp check_context_specific_rules(content, context) do
    case context do
      :timeline ->
        # Timeline-specific rules
        cond do
          count_hashtags(content) > 10 ->
            {:error, :too_many_hashtags}

          count_mentions(content) > 5 ->
            {:error, :too_many_mentions}

          true ->
            :ok
        end

      :discussion ->
        # Discussion-specific rules
        if String.length(String.trim(content)) < 10 do
          {:error, :discussion_too_short}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp sanitize_content(content) do
    content
    # Remove null bytes
    |> String.replace(~r/\0/, "")
    # Normalize whitespace but preserve newlines
    # Replace multiple spaces/tabs (but not newlines) with single space
    |> String.replace(~r/[^\S\n]+/, " ")
    # Remove trailing whitespace from each line
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
    # Trim leading/trailing whitespace from entire content
    |> String.trim()
  end

  defp count_hashtags(content) do
    Regex.scan(~r/#\w+/, content) |> length()
  end

  defp count_mentions(content) do
    Regex.scan(~r/@\w+/, content) |> length()
  end

  defp detect_duplicate_content?(_user_id, content) do
    # Check if user has posted identical content recently
    # This is a simplified version - could use database for persistence
    # content_hash = :crypto.hash(:sha256, content) |> Base.encode16()

    # Use length and basic repeat-pattern checks for the lightweight path.
    # In production, this would store hashes in database/cache
    String.length(content) < 10 && Regex.match?(~r/^(.)\1*$/, content)
  end

  @doc """
  Validates URL safety for link previews and shared content.
  """
  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, :invalid_protocol}

      String.contains?(uri.host || "", ["localhost", "127.0.0.1", "0.0.0.0"]) ->
        {:error, :localhost_not_allowed}

      String.length(url) > 2000 ->
        {:error, :url_too_long}

      true ->
        {:ok, url}
    end
  end

  @doc """
  Checks if a user is allowed to perform an action based on their account status.
  """
  def check_user_permissions(user, action) do
    cond do
      user.banned ->
        {:error, :user_banned}

      user.suspended ->
        {:error, :user_suspended}

      action in [:create_post, :promote_content] && user.suspended ->
        {:error, :user_suspended}

      true ->
        :ok
    end
  end
end
