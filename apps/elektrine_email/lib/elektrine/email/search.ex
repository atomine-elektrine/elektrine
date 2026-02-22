defmodule Elektrine.Email.Search do
  @moduledoc """
  Email search functionality.
  Handles message search with support for blind index searching of encrypted content.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Email.{Mailbox, Message}
  alias Elektrine.Repo

  # Private helper to decrypt email messages
  defp decrypt_email_messages(messages, mailbox_id) when is_list(messages) do
    case Elektrine.Email.Mailboxes.get_mailbox(mailbox_id) do
      %Mailbox{user_id: user_id} when not is_nil(user_id) ->
        Message.decrypt_messages(messages, user_id)

      _ ->
        messages
    end
  end

  @doc """
  Searches messages in a mailbox.
  Supports searching in from, to, cc, subject, and body content.
  Returns paginated results with metadata.
  """
  def search_messages(mailbox_id, query, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Get user_id from mailbox for blind index search
    case Elektrine.Email.Mailboxes.get_mailbox(mailbox_id) do
      nil ->
        %{
          messages: [],
          query: query,
          page: page,
          per_page: per_page,
          total_count: 0,
          total_pages: 0,
          has_next: false,
          has_prev: false
        }

      mailbox ->
        user_id = mailbox.user_id

        # Extract keywords from query and hash them for blind index search
        keywords = Elektrine.Encryption.extract_keywords(query)

        if Enum.empty?(keywords) do
          # No valid keywords, return empty results
          %{
            messages: [],
            query: query,
            page: page,
            per_page: per_page,
            total_count: 0,
            total_pages: 0,
            has_next: false,
            has_prev: false
          }
        else
          # Hash each keyword for this user
          keyword_hashes =
            Enum.map(keywords, fn kw ->
              Elektrine.Encryption.hash_keyword(kw, user_id)
            end)

          # Build search query using blind index
          base_query =
            Message
            |> where(mailbox_id: ^mailbox_id)
            |> where([m], not m.spam)
            |> where([m], not m.archived)
            |> where([m], not m.deleted)
            |> where([m], m.status != "sent" or is_nil(m.status) or m.from == m.to)

          # Split query into terms for metadata search (subject, from, to, cc)
          search_terms = String.split(String.trim(query), " ")

          # Apply search filters - search metadata fields with ILIKE and body with blind index
          search_query =
            Enum.reduce(search_terms, base_query, fn term, acc_query ->
              # Sanitize search term to prevent LIKE pattern injection
              safe_term = sanitize_search_term(term)
              search_term = "%#{String.downcase(safe_term)}%"

              where(
                acc_query,
                [m],
                ilike(fragment("LOWER(?)", m.from), ^search_term) or
                  ilike(fragment("LOWER(?)", m.to), ^search_term) or
                  ilike(fragment("LOWER(?)", m.cc), ^search_term) or
                  ilike(fragment("LOWER(?)", m.subject), ^search_term) or
                  fragment("? && ?", m.search_index, ^keyword_hashes)
              )
            end)

          # Get total count
          total_count = search_query |> Repo.aggregate(:count)

          # Get messages for current page
          messages =
            search_query
            |> order_by(desc: :inserted_at)
            |> limit(^per_page)
            |> offset(^offset)
            |> Repo.all()
            |> decrypt_email_messages(mailbox_id)

          # Calculate pagination metadata
          total_pages = ceil(total_count / per_page)
          has_next = page < total_pages
          has_prev = page > 1

          %{
            messages: messages,
            query: query,
            page: page,
            per_page: per_page,
            total_count: total_count,
            total_pages: total_pages,
            has_next: has_next,
            has_prev: has_prev
          }
        end
    end
  end

  @doc """
  Gets all unique recipient domains from sent messages across all users.
  Returns a list of %{domain: domain, count: message_count} maps.
  """
  def get_unique_recipient_domains do
    # Query to extract domains from TO, CC, and BCC fields in sent messages
    query = """
    WITH recipient_domains AS (
      SELECT
        LOWER(REGEXP_REPLACE(
          REGEXP_REPLACE(
            unnest(string_to_array(m.to || ',' || COALESCE(m.cc, '') || ',' || COALESCE(m.bcc, ''), ',')),
            '.*<(.+@.+)>.*', '\\1'
          ),
          '^[^@]+@(.+)$', '\\1'
        )) as domain,
        m.id as message_id
      FROM email_messages m
      WHERE m.status = 'sent'
        AND (m.to IS NOT NULL OR m.cc IS NOT NULL OR m.bcc IS NOT NULL)
    )
    SELECT domain, COUNT(DISTINCT message_id) as message_count
    FROM recipient_domains
    WHERE domain IS NOT NULL
      AND domain != ''
      AND domain ~ '^[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$'
    GROUP BY domain
    ORDER BY message_count DESC, domain
    """

    case Repo.query(query) do
      {:ok, result} ->
        result.rows
        |> Enum.map(fn [domain, count] -> %{domain: domain, count: count} end)
        # Exclude our own domains
        |> Enum.reject(&(&1.domain in ["elektrine.com", "z.org"]))

      {:error, _} ->
        []
    end
  end

  @doc """
  Gets unique recipient domains with pagination.
  """
  def get_unique_recipient_domains_paginated(page \\ 1, per_page \\ 50) do
    offset = (page - 1) * per_page

    # Same query as above but with pagination
    query = """
    WITH recipient_domains AS (
      SELECT
        LOWER(REGEXP_REPLACE(
          REGEXP_REPLACE(
            unnest(string_to_array(m.to || ',' || COALESCE(m.cc, '') || ',' || COALESCE(m.bcc, ''), ',')),
            '.*<(.+@.+)>.*', '\\1'
          ),
          '^[^@]+@(.+)$', '\\1'
        )) as domain,
        m.id as message_id
      FROM email_messages m
      WHERE m.status = 'sent'
        AND (m.to IS NOT NULL OR m.cc IS NOT NULL OR m.bcc IS NOT NULL)
    )
    SELECT domain, COUNT(DISTINCT message_id) as message_count
    FROM recipient_domains
    WHERE domain IS NOT NULL
      AND domain != ''
      AND domain ~ '^[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$'
    GROUP BY domain
    ORDER BY message_count DESC, domain
    LIMIT $1 OFFSET $2
    """

    # Get total count
    count_query = """
    WITH recipient_domains AS (
      SELECT
        LOWER(REGEXP_REPLACE(
          REGEXP_REPLACE(
            unnest(string_to_array(m.to || ',' || COALESCE(m.cc, '') || ',' || COALESCE(m.bcc, ''), ',')),
            '.*<(.+@.+)>.*', '\\1'
          ),
          '^[^@]+@(.+)$', '\\1'
        )) as domain
      FROM email_messages m
      WHERE m.status = 'sent'
        AND (m.to IS NOT NULL OR m.cc IS NOT NULL OR m.bcc IS NOT NULL)
    )
    SELECT COUNT(DISTINCT domain) as total
    FROM recipient_domains
    WHERE domain IS NOT NULL
      AND domain != ''
      AND domain ~ '^[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$'
    """

    case {Repo.query(query, [per_page, offset]), Repo.query(count_query)} do
      {{:ok, result}, {:ok, count_result}} ->
        domains =
          result.rows
          |> Enum.map(fn [domain, count] -> %{domain: domain, count: count} end)
          |> Enum.reject(&(&1.domain in ["elektrine.com", "z.org"]))

        total_count = count_result.rows |> List.first() |> List.first() || 0
        {domains, total_count}

      _ ->
        {[], 0}
    end
  end

  # Sanitize search terms to prevent LIKE pattern injection
  defp sanitize_search_term(term), do: Elektrine.TextHelpers.sanitize_search_term(term)
end
