defmodule Elektrine.Email.Categorizer do
  @moduledoc """
  Advanced email categorization and detection logic.
  Provides sophisticated detection for bulk emails, receipts, newsletters, and notifications.
  """

  @doc """
  Categorizes an email message based on its content and metadata.
  Returns the message attributes with category and detection flags set.
  """
  def categorize_message(message_attrs) do
    subject = String.downcase(message_attrs["subject"] || "")
    from = String.downcase(message_attrs["from"] || "")
    to = String.downcase(message_attrs["to"] || "")
    body = String.downcase(message_attrs["text_body"] || "")
    html_body = String.downcase(message_attrs["html_body"] || "")
    headers = message_attrs["metadata"]["headers"] || %{}

    # Combine text and HTML body for analysis
    combined_body = "#{body} #{html_body}"

    # Run all detection methods
    is_bulk = detect_bulk_email(headers, from, to, combined_body)
    is_receipt = detect_receipt(subject, from, combined_body, html_body)
    is_newsletter = detect_newsletter(subject, from, combined_body, headers)
    is_notification = detect_notification(subject, from, combined_body)

    # Determine category based on detection results
    category = determine_category(is_bulk, is_receipt, is_newsletter, is_notification)

    # Apply detection results
    message_attrs
    |> Map.put("category", category)
    |> Map.put("is_receipt", is_receipt)
    |> Map.put("is_newsletter", is_newsletter)
    |> Map.put("is_notification", is_notification)
  end

  @doc """
  Detects if an email is a bulk email using multiple signals.
  """
  def detect_bulk_email(headers, from, to, body) do
    # Check for bulk email headers
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

    header_score =
      Enum.count(bulk_headers, fn header ->
        Map.has_key?(headers, header) || Map.has_key?(headers, String.upcase(header))
      end)

    # Check precedence header value
    precedence = headers["precedence"] || headers["Precedence"] || ""

    precedence_score =
      if String.contains?(String.downcase(precedence), ["bulk", "list", "junk"]), do: 3, else: 0

    # Check for marketing/promotional keywords
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

    keyword_count = Enum.count(marketing_keywords, &String.contains?(body, &1))
    keyword_score = min(keyword_count, 5)

    # Check for bulk sender patterns
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
      # Pangle ads network
      ~r/pangle/i,
      ~r/mailchimp/i,
      ~r/sendgrid/i,
      ~r/constantcontact/i
    ]

    sender_score = if Enum.any?(bulk_sender_patterns, &Regex.match?(&1, from)), do: 2, else: 0

    # Check if "to" field suggests bulk (undisclosed recipients, mailing list, etc.)
    to_score =
      if String.contains?(to, ["undisclosed", "recipients", "list", "group"]), do: 2, else: 0

    # Check for tracking pixels (common in bulk email)
    tracking_score =
      if String.contains?(body, ["1x1", "track", "pixel", "beacon", "analytics"]), do: 1, else: 0

    # Calculate total score
    total_score =
      header_score + precedence_score + keyword_score + sender_score + to_score + tracking_score

    # Score threshold for bulk detection
    total_score >= 3
  end

  @doc """
  Detects if an email is a receipt or transaction confirmation.
  """
  def detect_receipt(subject, from, body, html_body) do
    # Strong receipt indicators in subject
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

    # But exclude if it's clearly a newsletter
    newsletter_exclusions = ["digest", "newsletter", "weekly", "daily", "monthly"]

    subject_score =
      cond do
        # If it has newsletter terms, it's not a receipt
        Enum.any?(newsletter_exclusions, &String.contains?(subject, &1)) -> 0
        # Otherwise check for receipt terms
        Enum.any?(strong_subject_terms, &String.contains?(subject, &1)) -> 5
        true -> 0
      end

    # Receipt keywords in body
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

    keyword_count = Enum.count(receipt_keywords, &String.contains?(body, &1))
    keyword_score = round(min(keyword_count * 0.5, 5))

    # Check for currency symbols and price patterns
    price_patterns = [
      # $10 or $10.99
      ~r/\$\d+\.?\d*/,
      # USD 10
      ~r/USD\s*\d+/i,
      # €10
      ~r/€\d+/,
      # £10
      ~r/£\d+/,
      # Total: $10
      ~r/total[:\s]+\$?\d+/i,
      # Amount: 10
      ~r/amount[:\s]+\$?\d+/i,
      # Price: $10
      ~r/price[:\s]+\$?\d+/i
    ]

    price_score = if Enum.any?(price_patterns, &Regex.match?(&1, body)), do: 3, else: 0

    # Check for common receipt senders
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

    sender_score = if Enum.any?(receipt_senders, &String.contains?(from, &1)), do: 2, else: 0

    # Check for table structure (common in receipts)
    table_score =
      if html_body != "" && String.contains?(html_body, ["<table", "<tr>", "<td>", "border"]),
        do: 1,
        else: 0

    # Calculate total score
    total_score = subject_score + keyword_score + price_score + sender_score + table_score

    # Score threshold for receipt detection
    total_score >= 5
  end

  @doc """
  Detects if an email is a newsletter.
  """
  def detect_newsletter(subject, from, body, headers) do
    # Newsletter headers
    header_score =
      if Map.has_key?(headers, "list-unsubscribe") || Map.has_key?(headers, "List-Unsubscribe"),
        do: 3,
        else: 0

    # Newsletter keywords in subject
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

    # Give extra weight to "digest" and "daily digest" in subject
    subject_score =
      cond do
        # Strong indicator
        String.contains?(subject, ["digest", "Daily Digest"]) -> 5
        # Specific known newsletters
        String.contains?(subject, ["Medium Daily", "Pangle"]) -> 5
        Enum.any?(newsletter_subject_terms, &String.contains?(subject, &1)) -> 3
        true -> 0
      end

    # Newsletter patterns in body
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

    keyword_count = Enum.count(newsletter_body_terms, &String.contains?(body, &1))
    body_score = min(keyword_count, 4)

    # Newsletter sender patterns
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

    sender_score =
      if Enum.any?(newsletter_sender_patterns, &Regex.match?(&1, from)), do: 2, else: 0

    # Check for publication/media domains (strong newsletter indicator)
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

    media_score = if Enum.any?(media_domains, &String.contains?(from, &1)), do: 4, else: 0

    # Calculate total score
    total_score = header_score + subject_score + body_score + sender_score + media_score

    # Score threshold for newsletter detection
    total_score >= 4
  end

  @doc """
  Detects if an email is an automated notification.
  """
  def detect_notification(subject, from, body) do
    # Strong notification indicators (MUST stay in inbox)
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

    # AWS specific critical notifications
    aws_critical =
      String.contains?(from, "amazonaws.com") &&
        (String.contains?(subject, "risk") ||
           String.contains?(subject, "suspended") ||
           String.contains?(subject, "immediate"))

    strong_score =
      cond do
        # AWS critical alerts always stay in inbox
        aws_critical -> 10
        Enum.any?(strong_indicators, &String.contains?(body, &1)) -> 5
        true -> 0
      end

    # Notification keywords
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

    keyword_count = Enum.count(notification_keywords, &String.contains?(body, &1))
    keyword_score = round(min(keyword_count * 0.7, 4))

    # Check sender patterns
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

    sender_score =
      if Enum.any?(notification_sender_patterns, &Regex.match?(&1, from)), do: 2, else: 0

    # Service notification patterns
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

    service_score = if Enum.any?(service_patterns, &String.contains?(from, &1)), do: 1, else: 0

    # Short body length often indicates notifications
    length_score = if String.length(body) < 500, do: 1, else: 0

    # Calculate total score
    total_score = strong_score + keyword_score + sender_score + service_score + length_score

    # Score threshold for notification detection
    total_score >= 4
  end

  # Determines the category based on detection results with clear priority
  defp determine_category(is_bulk, is_receipt, is_newsletter, is_notification) do
    # Priority order is critical for correct categorization:
    # 1. Newsletters/Digests (even if they contain payment info)
    # 2. Bulk emails (marketing, promotional)
    # 3. Pure receipts/invoices (financial records)
    # 4. Important notifications (security, account alerts)
    # 5. Everything else stays in inbox

    cond do
      # FEED: Newsletters, digests, and bulk notifications
      # Note: "feed" is the actual category name used for digest emails in the system
      is_newsletter -> "feed"
      # FEED: Marketing and bulk emails
      is_bulk && !is_receipt -> "feed"
      # LEDGER: Pure financial records (receipts/invoices that aren't bulk)
      is_receipt && !is_bulk && !is_newsletter -> "ledger"
      # LEDGER: Bulk receipts (like subscription renewals) still go to ledger
      is_receipt && is_bulk && !is_newsletter -> "ledger"
      # INBOX: Important security/account notifications
      is_notification && !is_bulk && !is_newsletter -> "inbox"
      # FEED: Bulk notifications (app updates, etc.)
      is_notification && is_bulk -> "feed"
      # FEED: Any remaining bulk email
      is_bulk -> "feed"
      # INBOX: Everything else (personal emails, important messages)
      true -> "inbox"
    end
  end
end
