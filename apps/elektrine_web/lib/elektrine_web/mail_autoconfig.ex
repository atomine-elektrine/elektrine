defmodule ElektrineWeb.MailAutoconfig do
  @moduledoc false

  alias Elektrine.MailClientSettings

  def autodiscover_ssl_value(settings) do
    if MailClientSettings.ssl?(settings), do: "on", else: "off"
  end

  def autodiscover_encryption(settings) do
    if MailClientSettings.starttls?(settings), do: "TLS"
  end

  def plist_bool_tag(settings) do
    if MailClientSettings.ssl?(settings), do: "<true/>", else: "<false/>"
  end
end
