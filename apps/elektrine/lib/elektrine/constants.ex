defmodule Elektrine.Constants do
  @moduledoc """
  Application-wide constants and limits.

  This module centralizes magic numbers used throughout the application
  to improve maintainability and consistency.
  """

  # File Upload Limits (in bytes)
  # 25MB
  @max_chat_attachment_size 25 * 1024 * 1024
  # 250MB
  @max_chat_attachment_size_admin 250 * 1024 * 1024
  # 25MB
  @max_email_attachment_size 25 * 1024 * 1024
  # 250MB
  @max_email_attachment_size_admin 250 * 1024 * 1024
  # 50MB
  @max_email_message_size 50 * 1024 * 1024
  # 1MB
  @max_favicon_size 1 * 1024 * 1024

  def max_chat_attachment_size, do: @max_chat_attachment_size
  def max_chat_attachment_size_admin, do: @max_chat_attachment_size_admin
  def max_email_attachment_size, do: @max_email_attachment_size
  def max_email_attachment_size_admin, do: @max_email_attachment_size_admin
  def max_email_message_size, do: @max_email_message_size
  def max_favicon_size, do: @max_favicon_size

  # SMTP Server Limits
  # 50MB
  @smtp_max_data_size 50 * 1024 * 1024
  # Reduced from 1000 to limit bot abuse
  @smtp_max_connections 50
  # Drastically reduced from 50 to stop bot spam
  @smtp_max_connections_per_ip 2
  # Reduced from 100
  @smtp_max_recipients 20
  # 30 seconds
  @smtp_send_timeout_ms 30_000
  # Reduced from 5 min to 1 min to free connections faster
  @smtp_timeout_ms 60_000

  def smtp_max_data_size, do: @smtp_max_data_size
  def smtp_max_connections, do: @smtp_max_connections
  def smtp_max_connections_per_ip, do: @smtp_max_connections_per_ip
  def smtp_max_recipients, do: @smtp_max_recipients
  def smtp_send_timeout_ms, do: @smtp_send_timeout_ms
  def smtp_timeout_ms, do: @smtp_timeout_ms

  # IMAP Server Limits
  # Reduced from 2000
  @imap_max_connections 100
  # Reduced from 200 (need some for multiple folders)
  @imap_max_connections_per_ip 10
  # Reduced from 1 hour to 30 min
  @imap_connection_timeout_ms 30 * 60 * 1000
  # Reduced from 15 to 10 minutes
  @imap_inactivity_timeout_ms 10 * 60 * 1000
  # 30 seconds
  @imap_send_timeout_ms 30_000
  # 50MB
  @imap_max_message_size 50 * 1024 * 1024
  # Apple Mail needs ~10 (one per folder)
  @imap_max_idle_per_ip 15
  # Reduced from 30 to 15 minutes
  @imap_idle_timeout_ms 15 * 60 * 1000

  def imap_max_connections, do: @imap_max_connections
  def imap_max_connections_per_ip, do: @imap_max_connections_per_ip
  def imap_connection_timeout_ms, do: @imap_connection_timeout_ms
  def imap_inactivity_timeout_ms, do: @imap_inactivity_timeout_ms
  def imap_send_timeout_ms, do: @imap_send_timeout_ms
  def imap_max_message_size, do: @imap_max_message_size
  def imap_max_idle_per_ip, do: @imap_max_idle_per_ip
  def imap_idle_timeout_ms, do: @imap_idle_timeout_ms

  # POP3 Server Limits
  # Reduced from 2000
  @pop3_max_connections 50
  # Reduced from 200
  @pop3_max_connections_per_ip 3
  # 30 seconds
  @pop3_send_timeout_ms 30_000
  # Reduced from 10 min to 2 min
  @pop3_timeout_ms 120_000

  def pop3_max_connections, do: @pop3_max_connections
  def pop3_max_connections_per_ip, do: @pop3_max_connections_per_ip
  def pop3_send_timeout_ms, do: @pop3_send_timeout_ms
  def pop3_timeout_ms, do: @pop3_timeout_ms

  # HTTP/API Timeouts (in milliseconds)
  # 30 seconds
  @http_timeout_default 30_000
  # 5 seconds
  @http_timeout_short 5_000
  # 15 seconds
  @http_timeout_medium 15_000
  # 60 seconds
  @http_timeout_long 60_000
  # 45 seconds
  @websocket_timeout 45_000

  def http_timeout_default, do: @http_timeout_default
  def http_timeout_short, do: @http_timeout_short
  def http_timeout_medium, do: @http_timeout_medium
  def http_timeout_long, do: @http_timeout_long
  def websocket_timeout, do: @websocket_timeout

  # Session/Auth Timeouts
  # 60 days
  @session_max_age_days 60
  # 60 days in seconds
  @session_max_age_seconds 60 * 60 * 24 * 60

  def session_max_age_days, do: @session_max_age_days
  def session_max_age_seconds, do: @session_max_age_seconds

  # Call/WebRTC Timeouts
  # 30 seconds
  @call_ring_timeout_ms 30_000

  def call_ring_timeout_ms, do: @call_ring_timeout_ms

  # User Limits
  @max_profile_links 50
  @max_profile_widgets 5
  @registration_limit_per_request 1

  def max_profile_links, do: @max_profile_links
  def max_profile_widgets, do: @max_profile_widgets
  def registration_limit_per_request, do: @registration_limit_per_request

  # Moderation Timeouts (in seconds)
  # 5 minutes
  @timeout_5min 300
  # 1 hour
  @timeout_1hr 3600

  def timeout_5min, do: @timeout_5min
  def timeout_1hr, do: @timeout_1hr

  # Safe timeout parsing defaults
  @parse_timeout_min 1
  @parse_timeout_max 300

  def parse_timeout_min, do: @parse_timeout_min
  def parse_timeout_max, do: @parse_timeout_max
end
