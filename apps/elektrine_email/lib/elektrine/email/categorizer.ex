defmodule Elektrine.Email.Categorizer do
  @moduledoc """
  Advanced email categorization and detection logic.
  Provides sophisticated detection for bulk emails, receipts, newsletters, and notifications.
  """

  @bulk_threshold 3
  @receipt_threshold 5
  @newsletter_threshold 4
  @notification_threshold 4
  @low_confidence_threshold 0.55

  @doc """
  Categorizes an email message based on its content, metadata, and learned preferences.
  Returns the message attributes with category and detection flags set.
  """
  def categorize_message(message_attrs, opts \\ []) do
    subject = normalize_text(get_attr(message_attrs, "subject", :subject))
    from = normalize_text(get_attr(message_attrs, "from", :from))
    to = normalize_text(get_attr(message_attrs, "to", :to))
    body = normalize_text(get_attr(message_attrs, "text_body", :text_body))
    html_body = normalize_text(get_attr(message_attrs, "html_body", :html_body))

    metadata =
      message_attrs
      |> get_attr("metadata", :metadata)
      |> normalize_metadata()

    headers = metadata |> Map.get("headers", %{}) |> normalize_headers()
    combined_body = "#{body} #{html_body}"

    bulk_signal = detect_bulk_email_signal(headers, from, to, combined_body)
    receipt_signal = detect_receipt_signal(subject, from, combined_body, html_body)
    newsletter_signal = detect_newsletter_signal(subject, from, combined_body, headers)
    notification_signal = detect_notification_signal(subject, from, combined_body)

    signals = %{
      bulk: bulk_signal,
      receipt: receipt_signal,
      newsletter: newsletter_signal,
      notification: notification_signal
    }

    user_id = Keyword.get(opts, :user_id)
    learned_match = match_learned_preference(user_id, get_attr(message_attrs, "from", :from))

    {category, confidence, source, reasons, fallback_applied} =
      determine_category(signals, learned_match)

    categorization_metadata = %{
      "category" => category,
      "confidence" => confidence,
      "source" => source,
      "fallback_applied" => fallback_applied,
      "reasons" => reasons,
      "signals" => %{
        "bulk" => signal_to_metadata(bulk_signal),
        "receipt" => signal_to_metadata(receipt_signal),
        "newsletter" => signal_to_metadata(newsletter_signal),
        "notification" => signal_to_metadata(notification_signal)
      }
    }

    updated_metadata = Map.put(metadata, "categorization", categorization_metadata)

    message_attrs
    |> put_attr("category", :category, category)
    |> put_attr("is_receipt", :is_receipt, receipt_signal.matched)
    |> put_attr("is_newsletter", :is_newsletter, newsletter_signal.matched)
    |> put_attr("is_notification", :is_notification, notification_signal.matched)
    |> put_attr("metadata", :metadata, updated_metadata)
  end

  @doc """
  Detects if an email is a bulk email using multiple signals.
  """
  def detect_bulk_email(headers, from, to, body) do
    headers
    |> normalize_headers()
    |> detect_bulk_email_signal(normalize_text(from), normalize_text(to), normalize_text(body))
    |> Map.get(:matched, false)
  end

  @doc """
  Detects if an email is a receipt or transaction confirmation.
  """
  def detect_receipt(subject, from, body, html_body) do
    subject
    |> normalize_text()
    |> detect_receipt_signal(
      normalize_text(from),
      normalize_text(body),
      normalize_text(html_body)
    )
    |> Map.get(:matched, false)
  end

  @doc """
  Detects if an email is a newsletter.
  """
  def detect_newsletter(subject, from, body, headers) do
    subject
    |> normalize_text()
    |> detect_newsletter_signal(
      normalize_text(from),
      normalize_text(body),
      normalize_headers(headers)
    )
    |> Map.get(:matched, false)
  end

  @doc """
  Detects if an email is an automated notification.
  """
  def detect_notification(subject, from, body) do
    subject
    |> normalize_text()
    |> detect_notification_signal(normalize_text(from), normalize_text(body))
    |> Map.get(:matched, false)
  end

  defp detect_bulk_email_signal(headers, from, to, body) do
    bulk_headers = [
      "list-unsubscribe",
      "list-id",
      "list-post",
      "list-help",
      "list-subscribe",
      "precedence",
      "x-campaign-id",
      "x-mailer",
      "x-mail-id",
      "x-report-abuse"
    ]

    header_hits =
      Enum.filter(bulk_headers, fn header ->
        Map.has_key?(headers, header)
      end)

    header_score = length(header_hits)

    precedence = Map.get(headers, "precedence", "")

    precedence_score =
      if String.contains?(precedence, ["bulk", "list", "junk"]), do: 3, else: 0

    marketing_keywords = [
      "unsubscribe",
      "opt-out",
      "marketing",
      "promotional",
      "advertisement",
      "deal",
      "offer",
      "sale",
      "discount",
      "limited time",
      "act now",
      "click here",
      "buy now",
      "shop now",
      "special offer",
      "exclusive",
      "manage preferences",
      "email preferences",
      "subscription settings"
    ]

    keyword_hits = Enum.filter(marketing_keywords, &String.contains?(body, &1))
    keyword_score = min(length(keyword_hits), 5)

    bulk_sender_patterns = [
      ~r/no-?reply/i,
      ~r/newsletter/i,
      ~r/marketing/i,
      ~r/promotions?/i,
      ~r/campaigns?/i,
      ~r/updates?/i,
      ~r/notifications?/i,
      ~r/automated/i,
      ~r/system/i,
      ~r/info@/i,
      ~r/news@/i,
      ~r/hello@/i,
      ~r/support@/i,
      ~r/team@/i,
      ~r/pangle/i,
      ~r/mailchimp/i,
      ~r/sendgrid/i,
      ~r/constantcontact/i
    ]

    sender_bulk? = Enum.any?(bulk_sender_patterns, &Regex.match?(&1, from))
    sender_score = if sender_bulk?, do: 2, else: 0

    to_bulk? = String.contains?(to, ["undisclosed", "recipients", "list", "group"])
    to_score = if to_bulk?, do: 2, else: 0

    tracking_bulk? = String.contains?(body, ["1x1", "track", "pixel", "beacon", "analytics"])
    tracking_score = if tracking_bulk?, do: 1, else: 0

    total_score =
      header_score + precedence_score + keyword_score + sender_score + to_score + tracking_score

    reasons =
      []
      |> maybe_add_reason(
        header_hits != [],
        "bulk headers present: #{Enum.join(header_hits, ", ")}"
      )
      |> maybe_add_reason(precedence_score > 0, "precedence indicates bulk/list traffic")
      |> maybe_add_reason(keyword_score > 0, "marketing language detected")
      |> maybe_add_reason(sender_bulk?, "sender pattern matches bulk mailers")
      |> maybe_add_reason(to_bulk?, "recipient header pattern looks list-like")
      |> maybe_add_reason(tracking_bulk?, "tracking indicators detected")
      |> Enum.reverse()

    %{
      matched: total_score >= @bulk_threshold,
      score: total_score,
      threshold: @bulk_threshold,
      reasons: reasons
    }
  end

  defp detect_receipt_signal(subject, from, body, html_body) do
    strong_subject_terms = [
      "receipt",
      "invoice",
      "order confirmation",
      "payment confirmation",
      "purchase confirmation",
      "transaction",
      "order #",
      "invoice #",
      "payment received",
      "refund",
      "credit",
      "charge",
      "billing statement",
      "statement"
    ]

    newsletter_exclusions = ["digest", "newsletter", "weekly", "daily", "monthly"]

    subject_receipt? =
      Enum.any?(strong_subject_terms, &String.contains?(subject, &1)) &&
        !Enum.any?(newsletter_exclusions, &String.contains?(subject, &1))

    subject_score = if subject_receipt?, do: 5, else: 0

    receipt_keywords = [
      "total",
      "subtotal",
      "tax",
      "amount",
      "paid",
      "due",
      "billing",
      "invoice",
      "receipt",
      "transaction",
      "order",
      "item",
      "quantity",
      "price",
      "cost",
      "fee",
      "charge",
      "payment method",
      "credit card",
      "debit",
      "paypal",
      "venmo",
      "confirmation number",
      "reference number",
      "tracking number",
      "ship to",
      "bill to",
      "delivery",
      "shipping"
    ]

    keyword_hits = Enum.filter(receipt_keywords, &String.contains?(body, &1))
    keyword_score = round(min(length(keyword_hits) * 0.5, 5))

    price_patterns = [
      ~r/\$\d+\.?\d*/,
      ~r/USD\s*\d+/i,
      ~r/€\d+/,
      ~r/£\d+/,
      ~r/total[:\s]+\$?\d+/i,
      ~r/amount[:\s]+\$?\d+/i,
      ~r/price[:\s]+\$?\d+/i
    ]

    price_detected? = Enum.any?(price_patterns, &Regex.match?(&1, body))
    price_score = if price_detected?, do: 3, else: 0

    receipt_senders = [
      "receipt",
      "invoice",
      "billing",
      "payment",
      "order",
      "shop",
      "store",
      "amazon",
      "ebay",
      "paypal",
      "stripe",
      "square",
      "shopify",
      "uber",
      "lyft",
      "doordash",
      "grubhub"
    ]

    sender_receipt? = Enum.any?(receipt_senders, &String.contains?(from, &1))
    sender_score = if sender_receipt?, do: 2, else: 0

    table_receipt? =
      html_body != "" && String.contains?(html_body, ["<table", "<tr>", "<td>", "border"])

    table_score = if table_receipt?, do: 1, else: 0

    total_score = subject_score + keyword_score + price_score + sender_score + table_score

    reasons =
      []
      |> maybe_add_reason(subject_receipt?, "subject indicates a receipt or invoice")
      |> maybe_add_reason(keyword_score > 0, "receipt/payment language detected")
      |> maybe_add_reason(price_detected?, "currency/amount patterns detected")
      |> maybe_add_reason(sender_receipt?, "sender resembles billing or commerce traffic")
      |> maybe_add_reason(table_receipt?, "receipt-style HTML table structure detected")
      |> Enum.reverse()

    %{
      matched: total_score >= @receipt_threshold,
      score: total_score,
      threshold: @receipt_threshold,
      reasons: reasons
    }
  end

  defp detect_newsletter_signal(subject, from, body, headers) do
    list_unsubscribe? = Map.has_key?(headers, "list-unsubscribe")
    header_score = if list_unsubscribe?, do: 3, else: 0

    newsletter_subject_terms = [
      "newsletter",
      "weekly",
      "monthly",
      "daily",
      "digest",
      "roundup",
      "update",
      "news",
      "bulletin",
      "briefing",
      "edition",
      "issue #",
      "vol.",
      "volume",
      "highlights",
      "recap"
    ]

    {subject_score, subject_reason} =
      cond do
        String.contains?(subject, ["digest", "daily digest"]) ->
          {5, "subject contains digest phrasing"}

        String.contains?(subject, ["medium daily", "pangle"]) ->
          {5, "subject matches known digest sender patterns"}

        Enum.any?(newsletter_subject_terms, &String.contains?(subject, &1)) ->
          {3, "subject contains newsletter terms"}

        true ->
          {0, nil}
      end

    newsletter_body_terms = [
      "unsubscribe",
      "manage subscription",
      "email preferences",
      "view in browser",
      "read more",
      "continue reading",
      "this week",
      "this month",
      "in this issue",
      "highlights",
      "subscribe",
      "forward to a friend",
      "share this"
    ]

    body_hits = Enum.filter(newsletter_body_terms, &String.contains?(body, &1))
    body_score = min(length(body_hits), 4)

    newsletter_sender_patterns = [
      ~r/newsletter/i,
      ~r/news@/i,
      ~r/updates?@/i,
      ~r/weekly@/i,
      ~r/daily@/i,
      ~r/digest@/i,
      ~r/\.substack\./i,
      ~r/mailchimp/i,
      ~r/campaign/i
    ]

    sender_newsletter? = Enum.any?(newsletter_sender_patterns, &Regex.match?(&1, from))
    sender_score = if sender_newsletter?, do: 2, else: 0

    media_domains = [
      "medium.com",
      "substack.com",
      "nytimes.com",
      "wsj.com",
      "techcrunch.com",
      "theverge.com",
      "wired.com",
      "bloomberg.com",
      "reuters.com",
      "cnn.com",
      "bbc.com",
      "npr.org",
      "linkedin.com",
      "twitter.com",
      "facebook.com",
      "github.com",
      "stackoverflow.com",
      "reddit.com",
      "quora.com",
      "producthunt.com",
      "hackernews",
      "dev.to",
      "pangle.io",
      "panglepay",
      "mailchimp",
      "sendgrid",
      "constantcontact"
    ]

    media_sender? = Enum.any?(media_domains, &String.contains?(from, &1))
    media_score = if media_sender?, do: 4, else: 0

    total_score = header_score + subject_score + body_score + sender_score + media_score

    reasons =
      []
      |> maybe_add_reason(list_unsubscribe?, "list-unsubscribe header found")
      |> maybe_add_reason(!is_nil(subject_reason), subject_reason)
      |> maybe_add_reason(body_score > 0, "newsletter body patterns detected")
      |> maybe_add_reason(sender_newsletter?, "sender matches newsletter address patterns")
      |> maybe_add_reason(media_sender?, "sender domain resembles publication/platform updates")
      |> Enum.reverse()

    %{
      matched: total_score >= @newsletter_threshold,
      score: total_score,
      threshold: @newsletter_threshold,
      reasons: reasons
    }
  end

  defp detect_notification_signal(subject, from, body) do
    strong_indicators = [
      "password reset",
      "verification code",
      "confirm your",
      "security alert",
      "new login",
      "suspicious activity",
      "2fa code",
      "two-factor",
      "one-time password",
      "otp",
      "account at risk",
      "immediate action required",
      "account suspended",
      "unauthorized access"
    ]

    aws_critical? =
      String.contains?(from, "amazonaws.com") &&
        (String.contains?(subject, "risk") ||
           String.contains?(subject, "suspended") ||
           String.contains?(subject, "immediate"))

    strong_notification? = Enum.any?(strong_indicators, &String.contains?(body, &1))
    strong_score = if aws_critical? || strong_notification?, do: 5, else: 0

    notification_keywords = [
      "notification",
      "alert",
      "reminder",
      "notice",
      "update",
      "verify",
      "confirm",
      "activate",
      "reset",
      "expired",
      "action required",
      "important",
      "urgent",
      "automated",
      "do not reply",
      "no-reply",
      "system generated"
    ]

    keyword_hits = Enum.filter(notification_keywords, &String.contains?(body, &1))
    keyword_score = round(min(length(keyword_hits) * 0.7, 4))

    notification_sender_patterns = [
      ~r/no-?reply/i,
      ~r/notifications?@/i,
      ~r/alerts?@/i,
      ~r/system@/i,
      ~r/automated@/i,
      ~r/donotreply/i,
      ~r/accounts?@/i,
      ~r/security@/i,
      ~r/support@/i
    ]

    sender_notification? = Enum.any?(notification_sender_patterns, &Regex.match?(&1, from))
    sender_score = if sender_notification?, do: 2, else: 0

    service_patterns = [
      "github.com",
      "gitlab.com",
      "bitbucket.org",
      "slack.com",
      "discord.com",
      "teams.microsoft.com",
      "facebook.com",
      "twitter.com",
      "linkedin.com",
      "google.com",
      "apple.com",
      "microsoft.com",
      "dropbox.com",
      "box.com",
      "zoom.us"
    ]

    service_notification? = Enum.any?(service_patterns, &String.contains?(from, &1))
    service_score = if service_notification?, do: 1, else: 0

    short_body? = String.length(body) < 500
    length_score = if short_body?, do: 1, else: 0

    total_score = strong_score + keyword_score + sender_score + service_score + length_score

    reasons =
      []
      |> maybe_add_reason(aws_critical?, "critical cloud security phrasing detected")
      |> maybe_add_reason(strong_notification?, "security/account notification language detected")
      |> maybe_add_reason(keyword_score > 0, "notification keywords detected")
      |> maybe_add_reason(sender_notification?, "sender matches notification address patterns")
      |> maybe_add_reason(service_notification?, "sender appears to be a known service domain")
      |> maybe_add_reason(short_body?, "short-form body pattern common for alerts")
      |> Enum.reverse()

    %{
      matched: total_score >= @notification_threshold,
      score: total_score,
      threshold: @notification_threshold,
      reasons: reasons
    }
  end

  defp determine_category(_signals, learned_match) when is_map(learned_match) do
    category = learned_match.category
    confidence = normalize_confidence(Map.get(learned_match, :confidence, 0.8))
    source = Map.get(learned_match, :source, "learned")
    reasons = Map.get(learned_match, :reasons, ["learned category preference"])

    {category, confidence, source, reasons, false}
  end

  defp determine_category(signals, _learned_match) do
    bulk = signals.bulk
    receipt = signals.receipt
    newsletter = signals.newsletter
    notification = signals.notification

    {category, source, primary_signal} =
      cond do
        newsletter.matched ->
          {"feed", :newsletter, newsletter}

        bulk.matched && !receipt.matched ->
          {"feed", :bulk_non_receipt, bulk}

        receipt.matched && !newsletter.matched ->
          {"ledger", :receipt, receipt}

        notification.matched && !bulk.matched && !newsletter.matched ->
          {"inbox", :notification, notification}

        notification.matched && bulk.matched ->
          {"feed", :notification_bulk, bulk}

        bulk.matched ->
          {"feed", :bulk_fallback, bulk}

        true ->
          {"inbox", :default, nil}
      end

    confidence =
      source
      |> compute_confidence(primary_signal, signals)
      |> normalize_confidence()

    reasons =
      base_reasons(source, primary_signal)
      |> maybe_add_reason(
        category in ["feed", "ledger"] && confidence < @low_confidence_threshold,
        "confidence #{format_confidence(confidence)} below threshold #{@low_confidence_threshold}"
      )

    if category in ["feed", "ledger"] && confidence < @low_confidence_threshold do
      {"inbox", confidence, "confidence_fallback", Enum.reverse(reasons), true}
    else
      {category, confidence, Atom.to_string(source), Enum.reverse(reasons), false}
    end
  end

  defp compute_confidence(:default, _primary_signal, _signals), do: 0.9
  defp compute_confidence(:notification, _primary_signal, _signals), do: 0.85

  defp compute_confidence(source, primary_signal, signals) do
    base = signal_confidence(primary_signal)
    penalty = competing_penalty(source, signals)
    base + 0.2 - penalty
  end

  defp competing_penalty(:receipt, signals) do
    max(signal_confidence(signals.newsletter), signal_confidence(signals.bulk)) * 0.35
  end

  defp competing_penalty(:bulk_non_receipt, signals) do
    signal_confidence(signals.receipt) * 0.2
  end

  defp competing_penalty(_, _), do: 0.0

  defp signal_confidence(nil), do: 0.0

  defp signal_confidence(%{score: score, threshold: threshold})
       when is_number(score) and is_number(threshold) and threshold > 0 do
    min(1.0, score / (threshold * 2.0))
  end

  defp signal_confidence(_), do: 0.0

  defp base_reasons(:newsletter, primary_signal) do
    ["newsletter signal selected" | signal_reason_list(primary_signal)]
  end

  defp base_reasons(:bulk_non_receipt, primary_signal) do
    ["bulk non-receipt signal selected" | signal_reason_list(primary_signal)]
  end

  defp base_reasons(:receipt, primary_signal) do
    ["receipt signal selected" | signal_reason_list(primary_signal)]
  end

  defp base_reasons(:notification, primary_signal) do
    ["notification signal selected" | signal_reason_list(primary_signal)]
  end

  defp base_reasons(:notification_bulk, primary_signal) do
    ["bulk notification signal selected" | signal_reason_list(primary_signal)]
  end

  defp base_reasons(:bulk_fallback, primary_signal) do
    ["bulk fallback selected" | signal_reason_list(primary_signal)]
  end

  defp base_reasons(:default, _primary_signal) do
    ["no strong digest/ledger signals detected"]
  end

  defp signal_reason_list(%{reasons: reasons}) when is_list(reasons), do: reasons
  defp signal_reason_list(_), do: []

  defp signal_to_metadata(signal) do
    %{
      "matched" => Map.get(signal, :matched, false),
      "score" => Map.get(signal, :score, 0),
      "threshold" => Map.get(signal, :threshold, 0),
      "reasons" => Map.get(signal, :reasons, [])
    }
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.reduce(headers, %{}, fn {key, value}, acc ->
      normalized_key =
        key
        |> to_string()
        |> String.downcase()
        |> String.trim()

      normalized_value =
        value
        |> to_string()
        |> String.downcase()
        |> String.trim()

      Map.put(acc, normalized_key, normalized_value)
    end)
  end

  defp normalize_headers(_), do: %{}

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp normalize_text(value) when is_binary(value), do: String.downcase(value)
  defp normalize_text(_), do: ""

  defp get_attr(attrs, string_key, atom_key) when is_map(attrs) do
    Map.get(attrs, string_key) || Map.get(attrs, atom_key)
  end

  defp put_attr(attrs, string_key, atom_key, value) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, atom_key) ->
        Map.put(attrs, atom_key, value)

      Map.has_key?(attrs, string_key) ->
        Map.put(attrs, string_key, value)

      Enum.any?(Map.keys(attrs), &is_atom/1) ->
        Map.put(attrs, atom_key, value)

      true ->
        Map.put(attrs, string_key, value)
    end
  end

  defp maybe_add_reason(reasons, true, reason) when is_list(reasons), do: [reason | reasons]
  defp maybe_add_reason(reasons, _, _), do: reasons

  defp normalize_confidence(confidence) when is_number(confidence) do
    confidence
    |> max(0.0)
    |> min(0.99)
    |> Float.round(3)
  end

  defp normalize_confidence(_), do: 0.0

  defp format_confidence(confidence) when is_number(confidence) do
    :erlang.float_to_binary(confidence, decimals: 3)
  end

  defp format_confidence(_), do: "0.000"

  defp match_learned_preference(user_id, from) when is_integer(user_id) and is_binary(from) do
    Elektrine.Email.CategoryPreferences.match_category(user_id, from)
  end

  defp match_learned_preference(_, _), do: nil
end
