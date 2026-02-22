defmodule ElektrineWeb.DAV.AddressBookController do
  @moduledoc """
  CardDAV controller for contact synchronization.

  Implements RFC 6352 (CardDAV) for contact sync with:
  - iOS/macOS Contacts
  - Thunderbird
  - DAVx5 (Android)
  - Other CardDAV clients
  """

  use ElektrineWeb, :controller

  alias Elektrine.Email.{Contacts, VCard}
  alias ElektrineWeb.DAV.{Properties, ResponseHelpers}

  require Logger

  @doc """
  PROPFIND on addressbook home - lists available addressbooks.
  """
  def propfind_home(conn, %{"username" => username}) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      base_url = base_url(conn)
      depth = ResponseHelpers.get_depth(conn)

      responses = [
        # The home collection
        %{
          href: "#{base_url}/addressbooks/#{username}/",
          propstat: [{200, Properties.addressbook_home_props(user, base_url)}]
        }
      ]

      # If depth > 0, include the contacts addressbook
      responses =
        if depth != 0 do
          responses ++
            [
              %{
                href: "#{base_url}/addressbooks/#{username}/contacts/",
                propstat: [{200, Properties.addressbook_props(user, base_url)}]
              }
            ]
        else
          responses
        end

      ResponseHelpers.send_multistatus(conn, responses)
    end
  end

  @doc """
  PROPFIND on the contacts addressbook - lists contacts or properties.
  """
  def propfind_addressbook(conn, %{"username" => username}) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      base_url = base_url(conn)
      depth = ResponseHelpers.get_depth(conn)

      # Addressbook collection properties
      responses = [
        %{
          href: "#{base_url}/addressbooks/#{username}/contacts/",
          propstat: [{200, Properties.addressbook_props(user, base_url)}]
        }
      ]

      # If depth > 0, include all contacts
      responses =
        if depth != 0 do
          contacts = Contacts.list_contacts(user.id)

          contact_responses =
            Enum.map(contacts, fn contact ->
              %{
                href: "#{base_url}/addressbooks/#{username}/contacts/#{contact.uid}.vcf",
                propstat: [{200, Properties.contact_props(contact)}]
              }
            end)

          responses ++ contact_responses
        else
          responses
        end

      ResponseHelpers.send_multistatus(conn, responses)
    end
  end

  @doc """
  REPORT request - multiget or query contacts.
  """
  def report(conn, %{"username" => username}) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      cond do
        String.contains?(body, "addressbook-multiget") ->
          handle_multiget(conn, user, body)

        String.contains?(body, "addressbook-query") ->
          handle_query(conn, user, body)

        String.contains?(body, "sync-collection") ->
          handle_sync(conn, user, body)

        true ->
          ResponseHelpers.send_multistatus(conn, [])
      end
    end
  end

  @doc """
  GET a single contact as vCard.
  """
  def get_contact(conn, %{"username" => username, "contact_uid" => contact_uid}) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      # Remove .vcf extension if present
      uid = String.replace_suffix(contact_uid, ".vcf", "")

      case Contacts.get_contact_by_uid(user.id, uid) do
        nil ->
          ResponseHelpers.send_not_found(conn)

        contact ->
          # Generate or use stored vCard
          vcard_data = contact.vcard_data || generate_vcard(contact)
          ResponseHelpers.send_resource(conn, vcard_data, "text/vcard", contact.etag)
      end
    end
  end

  @doc """
  PUT (create or update) a contact.
  """
  def put_contact(conn, %{"username" => username, "contact_uid" => contact_uid}) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      uid = String.replace_suffix(contact_uid, ".vcf", "")
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      # Check If-Match header for conditional update
      if_match = get_req_header(conn, "if-match") |> List.first()
      if_none_match = get_req_header(conn, "if-none-match") |> List.first()

      existing = Contacts.get_contact_by_uid(user.id, uid)

      cond do
        # If-None-Match: * means only create, don't update
        if_none_match == "*" && existing ->
          ResponseHelpers.send_precondition_failed(conn)

        # If-Match means only update if etag matches
        if_match && existing && "\"#{existing.etag}\"" != if_match ->
          ResponseHelpers.send_precondition_failed(conn)

        # If-Match with no existing resource
        if_match && !existing ->
          ResponseHelpers.send_precondition_failed(conn)

        true ->
          # Parse vCard
          case VCard.parse(body) do
            {:ok, contact_data} ->
              contact_attrs =
                Map.merge(contact_data, %{
                  user_id: user.id,
                  uid: uid,
                  vcard_data: body,
                  # Derive primary email if not set
                  email: contact_data[:email] || get_primary_email(contact_data),
                  # Derive name if not set
                  name: contact_data[:name] || contact_data[:formatted_name] || "Unknown"
                })

              result =
                if existing do
                  Contacts.update_contact_carddav(existing, contact_attrs)
                else
                  Contacts.create_contact_carddav(contact_attrs)
                end

              case result do
                {:ok, contact} ->
                  # Update user's addressbook ctag
                  update_addressbook_ctag(user)

                  if existing do
                    ResponseHelpers.send_no_content(conn, contact.etag)
                  else
                    ResponseHelpers.send_created(conn, contact.etag)
                  end

                {:error, changeset} ->
                  Logger.error("CardDAV PUT failed: #{inspect(changeset.errors)}")

                  conn
                  |> put_resp_content_type("text/plain")
                  |> send_resp(400, "Invalid vCard data")
              end

            {:error, reason} ->
              Logger.error("CardDAV vCard parse failed: #{inspect(reason)}")

              conn
              |> put_resp_content_type("text/plain")
              |> send_resp(400, "Invalid vCard format")
          end
      end
    end
  end

  @doc """
  DELETE a contact.
  """
  def delete_contact(conn, %{"username" => username, "contact_uid" => contact_uid}) do
    user = conn.assigns.current_user

    if user.username != username do
      ResponseHelpers.send_forbidden(conn)
    else
      uid = String.replace_suffix(contact_uid, ".vcf", "")

      case Contacts.get_contact_by_uid(user.id, uid) do
        nil ->
          ResponseHelpers.send_not_found(conn)

        contact ->
          case Contacts.delete_contact(contact) do
            {:ok, _} ->
              update_addressbook_ctag(user)
              ResponseHelpers.send_no_content(conn)

            {:error, _} ->
              conn
              |> send_resp(500, "Failed to delete contact")
          end
      end
    end
  end

  # Private functions

  defp handle_multiget(conn, user, body) do
    # Extract hrefs from request body
    hrefs = extract_hrefs(body)
    _base_url = base_url(conn)

    responses =
      Enum.map(hrefs, fn href ->
        # Extract UID from href
        uid =
          href
          |> String.split("/")
          |> List.last()
          |> String.replace_suffix(".vcf", "")

        case Contacts.get_contact_by_uid(user.id, uid) do
          nil ->
            %{
              href: href,
              propstat: [{404, []}]
            }

          contact ->
            vcard_data = contact.vcard_data || generate_vcard(contact)
            props = Properties.contact_props(contact) ++ [{:address_data, vcard_data}]

            %{
              href: href,
              propstat: [{200, props}]
            }
        end
      end)

    ResponseHelpers.send_multistatus(conn, responses)
  end

  defp handle_query(conn, user, _body) do
    base_url = base_url(conn)

    # For simplicity, return all contacts
    # In production, would parse the query filter
    contacts = Contacts.list_contacts(user.id)

    responses =
      Enum.map(contacts, fn contact ->
        vcard_data = contact.vcard_data || generate_vcard(contact)
        props = Properties.contact_props(contact) ++ [{:address_data, vcard_data}]

        %{
          href: "#{base_url}/addressbooks/#{user.username}/contacts/#{contact.uid}.vcf",
          propstat: [{200, props}]
        }
      end)

    ResponseHelpers.send_multistatus(conn, responses)
  end

  defp handle_sync(conn, user, body) do
    base_url = base_url(conn)

    # Extract sync-token from request
    old_token = extract_sync_token(body)

    # Get contacts modified since token
    contacts =
      if old_token do
        # Parse token to get timestamp and return changes since then
        Contacts.list_contacts_since(user.id, parse_sync_token(old_token))
      else
        Contacts.list_contacts(user.id)
      end

    responses =
      Enum.map(contacts, fn contact ->
        props = Properties.contact_props(contact)

        %{
          href: "#{base_url}/addressbooks/#{user.username}/contacts/#{contact.uid}.vcf",
          propstat: [{200, props}]
        }
      end)

    # Include new sync token
    new_token = "data:,#{Properties.generate_addressbook_ctag(user)}"

    # Add sync-token to response
    responses =
      responses ++
        [
          %{
            href: "#{base_url}/addressbooks/#{user.username}/contacts/",
            propstat: [{200, [{:sync_token, new_token}]}]
          }
        ]

    ResponseHelpers.send_multistatus(conn, responses)
  end

  defp extract_hrefs(body) do
    Regex.scan(~r/<D:href>([^<]+)<\/D:href>/i, body)
    |> Enum.map(fn [_, href] -> href end)
  end

  defp extract_sync_token(body) do
    case Regex.run(~r/<D:sync-token>([^<]+)<\/D:sync-token>/i, body) do
      [_, token] -> token
      _ -> nil
    end
  end

  defp parse_sync_token("data:," <> ctag) do
    case String.split(ctag, "-") do
      ["ctag", timestamp] ->
        case Integer.parse(timestamp) do
          {ts, _} -> DateTime.from_unix!(ts)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_sync_token(_), do: nil

  defp generate_vcard(contact) do
    case VCard.generate(contact) do
      {:ok, vcard} -> vcard
      {:error, _} -> ""
    end
  end

  defp get_primary_email(%{emails: [first | _]}) do
    Map.get(first, "value") || Map.get(first, :value)
  end

  defp get_primary_email(%{email: email}) when is_binary(email), do: email
  defp get_primary_email(_), do: nil

  defp base_url(conn) do
    scheme = if conn.scheme == :https, do: "https", else: "http"
    port = if conn.port in [80, 443], do: "", else: ":#{conn.port}"
    "#{scheme}://#{conn.host}#{port}"
  end

  defp update_addressbook_ctag(user) do
    # Update the user's addressbook ctag for sync
    ctag = "ctag-#{DateTime.utc_now() |> DateTime.to_unix()}"
    Elektrine.Accounts.update_addressbook_ctag(user, ctag)
  end
end
