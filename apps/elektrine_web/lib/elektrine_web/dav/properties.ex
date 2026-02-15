defmodule ElektrineWeb.DAV.Properties do
  @moduledoc """
  DAV property definitions and builders for CalDAV/CardDAV.

  Provides standard WebDAV, CalDAV, and CardDAV property sets.
  """

  @doc """
  Returns the standard properties for a principal resource.
  """
  def principal_props(user, base_url) do
    [
      displayname: user.username,
      resourcetype: :collection,
      current_user_principal: "#{base_url}/principals/users/#{user.username}/",
      principal_url: "#{base_url}/principals/users/#{user.username}/",
      calendar_home_set: "#{base_url}/calendars/#{user.username}/",
      addressbook_home_set: "#{base_url}/addressbooks/#{user.username}/"
    ]
  end

  @doc """
  Returns the standard properties for a calendar home collection.
  """
  def calendar_home_props(user, base_url) do
    [
      displayname: "#{user.username}'s Calendars",
      resourcetype: :collection,
      current_user_principal: "#{base_url}/principals/users/#{user.username}/",
      owner: "#{base_url}/principals/users/#{user.username}/"
    ]
  end

  @doc """
  Returns the properties for a single calendar.
  """
  def calendar_props(calendar, base_url, user) do
    [
      displayname: calendar.name,
      resourcetype: :calendar,
      calendar_description: calendar.description,
      calendar_color: calendar.color,
      calendar_timezone: build_vtimezone(calendar.timezone),
      getctag: calendar.ctag || generate_ctag(calendar),
      sync_token: "data:,#{calendar.ctag || generate_ctag(calendar)}",
      supported_calendar_component_set: ["VEVENT", "VTODO"],
      owner: "#{base_url}/principals/users/#{user.username}/",
      current_user_principal: "#{base_url}/principals/users/#{user.username}/",
      supported_report_set: [
        "C:calendar-multiget",
        "C:calendar-query",
        "D:sync-collection"
      ]
    ]
  end

  @doc """
  Returns the properties for a calendar event.
  """
  def event_props(event) do
    [
      getetag: event.etag,
      getcontenttype: "text/calendar; charset=utf-8",
      getcontentlength: byte_size(event.icalendar_data || ""),
      getlastmodified: event.updated_at,
      resourcetype: nil
    ]
  end

  @doc """
  Returns the standard properties for an addressbook home collection.
  """
  def addressbook_home_props(user, base_url) do
    [
      displayname: "#{user.username}'s Address Books",
      resourcetype: :collection,
      current_user_principal: "#{base_url}/principals/users/#{user.username}/",
      owner: "#{base_url}/principals/users/#{user.username}/"
    ]
  end

  @doc """
  Returns the properties for the default addressbook.
  """
  def addressbook_props(user, base_url) do
    [
      displayname: "Contacts",
      resourcetype: :addressbook,
      getctag: user.addressbook_ctag || generate_addressbook_ctag(user),
      sync_token: "data:,#{user.addressbook_ctag || generate_addressbook_ctag(user)}",
      supported_address_data: true,
      owner: "#{base_url}/principals/users/#{user.username}/",
      current_user_principal: "#{base_url}/principals/users/#{user.username}/",
      supported_report_set: [
        "A:addressbook-multiget",
        "A:addressbook-query",
        "D:sync-collection"
      ]
    ]
  end

  @doc """
  Returns the properties for a contact (vCard).
  """
  def contact_props(contact) do
    vcard_data = contact.vcard_data || ""

    [
      getetag: contact.etag,
      getcontenttype: "text/vcard; charset=utf-8",
      getcontentlength: byte_size(vcard_data),
      getlastmodified: contact.updated_at,
      resourcetype: nil
    ]
  end

  @doc """
  Generates a ctag (collection tag) for sync detection.
  """
  def generate_ctag(%{updated_at: updated_at}) when not is_nil(updated_at) do
    timestamp = DateTime.to_unix(updated_at)
    "ctag-#{timestamp}"
  end

  def generate_ctag(_) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    "ctag-#{timestamp}"
  end

  @doc """
  Generates a ctag for an addressbook based on user's contacts.
  """
  def generate_addressbook_ctag(%{addressbook_ctag: ctag}) when not is_nil(ctag), do: ctag

  def generate_addressbook_ctag(%{updated_at: updated_at}) when not is_nil(updated_at) do
    timestamp = DateTime.to_unix(updated_at)
    "ctag-#{timestamp}"
  end

  def generate_addressbook_ctag(_) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    "ctag-#{timestamp}"
  end

  @doc """
  Builds a VTIMEZONE component for a timezone ID.
  """
  def build_vtimezone("UTC"), do: nil
  def build_vtimezone(nil), do: nil

  def build_vtimezone(timezone_id) do
    # Simplified VTIMEZONE - in production, would use a proper TZDB
    """
    BEGIN:VTIMEZONE
    TZID:#{timezone_id}
    BEGIN:STANDARD
    DTSTART:19700101T000000
    TZOFFSETFROM:+0000
    TZOFFSETTO:+0000
    END:STANDARD
    END:VTIMEZONE
    """
  end

  @doc """
  Returns all supported WebDAV properties.
  """
  def all_dav_props do
    [
      :displayname,
      :resourcetype,
      :getcontenttype,
      :getcontentlength,
      :getetag,
      :getlastmodified,
      :creationdate,
      :owner,
      :supported_report_set
    ]
  end

  @doc """
  Returns all supported CalDAV properties.
  """
  def all_caldav_props do
    [
      :calendar_description,
      :calendar_color,
      :calendar_timezone,
      :supported_calendar_component_set,
      :calendar_home_set
    ]
  end

  @doc """
  Returns all supported CardDAV properties.
  """
  def all_carddav_props do
    [
      :addressbook_home_set,
      :supported_address_data
    ]
  end
end
