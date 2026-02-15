defmodule Elektrine.Email.VCardTest do
  use ExUnit.Case, async: true

  alias Elektrine.Email.VCard

  describe "parse/1" do
    test "parses a simple vCard" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      UID:test-uid@example.com
      FN:John Doe
      N:Doe;John;;;
      EMAIL:john@example.com
      TEL:+1234567890
      END:VCARD
      """

      assert {:ok, contact} = VCard.parse(vcard)
      assert contact.uid == "test-uid@example.com"
      assert contact.formatted_name == "John Doe"
      assert contact.first_name == "John"
      assert contact.last_name == "Doe"
      assert [%{"value" => "john@example.com"}] = contact.emails
      assert [%{"value" => "+1234567890"}] = contact.phones
    end

    test "parses vCard with multiple emails and phones" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      UID:multi@example.com
      FN:Jane Smith
      EMAIL;TYPE=WORK:jane.work@example.com
      EMAIL;TYPE=HOME;PREF:jane.home@example.com
      TEL;TYPE=WORK:+1111111111
      TEL;TYPE=CELL:+2222222222
      END:VCARD
      """

      assert {:ok, contact} = VCard.parse(vcard)
      assert length(contact.emails) == 2
      assert length(contact.phones) == 2

      work_email = Enum.find(contact.emails, &(&1["type"] == "work"))
      assert work_email["value"] == "jane.work@example.com"

      home_email = Enum.find(contact.emails, &(&1["type"] == "home"))
      assert home_email["value"] == "jane.home@example.com"
      assert home_email["primary"] == true
    end

    test "parses vCard with address" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      UID:addr@example.com
      FN:Bob Jones
      ADR;TYPE=HOME:;;123 Main St;Springfield;IL;62701;USA
      END:VCARD
      """

      assert {:ok, contact} = VCard.parse(vcard)
      assert [address] = contact.addresses
      assert address["street"] == "123 Main St"
      assert address["city"] == "Springfield"
      assert address["region"] == "IL"
      assert address["postal_code"] == "62701"
      assert address["country"] == "USA"
    end

    test "parses vCard with organization" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      UID:org@example.com
      FN:Alice Worker
      ORG:Acme Corp
      TITLE:Software Engineer
      ROLE:Developer
      END:VCARD
      """

      assert {:ok, contact} = VCard.parse(vcard)
      assert contact.organization == "Acme Corp"
      assert contact.title == "Software Engineer"
      assert contact.role == "Developer"
    end

    test "parses vCard with birthday" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      UID:bday@example.com
      FN:Charlie Brown
      BDAY:1990-05-15
      END:VCARD
      """

      assert {:ok, contact} = VCard.parse(vcard)
      assert contact.birthday == ~D[1990-05-15]
    end

    test "parses vCard with categories" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      UID:cat@example.com
      FN:Dana White
      CATEGORIES:Friends,Coworkers,Important
      END:VCARD
      """

      assert {:ok, contact} = VCard.parse(vcard)
      assert contact.categories == ["Friends", "Coworkers", "Important"]
    end

    test "parses vCard with escaped characters" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      UID:escape@example.com
      FN:Test\\, User
      NOTE:Line one\\nLine two\\;with semicolon
      END:VCARD
      """

      assert {:ok, contact} = VCard.parse(vcard)
      assert contact.formatted_name == "Test, User"
      assert contact.notes == "Line one\nLine two;with semicolon"
    end

    test "handles folded lines" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      UID:fold@example.com
      FN:Very Long Name That Continues
       On Multiple Lines
      END:VCARD
      """

      assert {:ok, contact} = VCard.parse(vcard)
      assert contact.formatted_name == "Very Long Name That ContinuesOn Multiple Lines"
    end

    test "parses photo URL" do
      vcard = """
      BEGIN:VCARD
      VERSION:3.0
      UID:photo@example.com
      FN:Photo Person
      PHOTO;VALUE=URI:https://example.com/photo.jpg
      END:VCARD
      """

      assert {:ok, contact} = VCard.parse(vcard)
      assert contact.photo_type == "url"
      assert contact.photo_data == "https://example.com/photo.jpg"
    end
  end

  describe "generate/1" do
    test "generates a simple vCard" do
      contact = %{
        uid: "gen-test@example.com",
        formatted_name: "Test User",
        first_name: "Test",
        last_name: "User",
        email: "test@example.com"
      }

      assert {:ok, vcard} = VCard.generate(contact)
      assert String.contains?(vcard, "BEGIN:VCARD")
      assert String.contains?(vcard, "VERSION:3.0")
      assert String.contains?(vcard, "UID:gen-test@example.com")
      assert String.contains?(vcard, "FN:Test User")
      assert String.contains?(vcard, "N:User;Test;;;")
      assert String.contains?(vcard, "EMAIL")
      assert String.contains?(vcard, "END:VCARD")
    end

    test "generates vCard with multiple emails" do
      contact = %{
        uid: "multi-email@example.com",
        formatted_name: "Multi Email",
        emails: [
          %{"type" => "work", "value" => "work@example.com", "primary" => false},
          %{"type" => "home", "value" => "home@example.com", "primary" => true}
        ]
      }

      assert {:ok, vcard} = VCard.generate(contact)
      assert String.contains?(vcard, "EMAIL;TYPE=WORK")
      assert String.contains?(vcard, "work@example.com")
      assert String.contains?(vcard, "EMAIL;TYPE=HOME;PREF")
      assert String.contains?(vcard, "home@example.com")
    end

    test "generates vCard with organization info" do
      contact = %{
        uid: "org-gen@example.com",
        formatted_name: "Org Test",
        organization: "Test Corp",
        title: "Manager",
        role: "Team Lead"
      }

      assert {:ok, vcard} = VCard.generate(contact)
      assert String.contains?(vcard, "ORG:Test Corp")
      assert String.contains?(vcard, "TITLE:Manager")
      assert String.contains?(vcard, "ROLE:Team Lead")
    end

    test "generates vCard with address" do
      contact = %{
        uid: "addr-gen@example.com",
        formatted_name: "Address Test",
        addresses: [
          %{
            "type" => "home",
            "street" => "456 Oak Ave",
            "city" => "Chicago",
            "region" => "IL",
            "postal_code" => "60601",
            "country" => "USA"
          }
        ]
      }

      assert {:ok, vcard} = VCard.generate(contact)
      assert String.contains?(vcard, "ADR;TYPE=HOME:")
      assert String.contains?(vcard, "456 Oak Ave")
      assert String.contains?(vcard, "Chicago")
    end

    test "escapes special characters" do
      contact = %{
        uid: "escape-gen@example.com",
        formatted_name: "Test, User",
        notes: "Line one\nLine two;semicolon"
      }

      assert {:ok, vcard} = VCard.generate(contact)
      assert String.contains?(vcard, "FN:Test\\, User")
      assert String.contains?(vcard, "NOTE:Line one\\nLine two\\;semicolon")
    end

    test "folds long lines" do
      long_note = String.duplicate("x", 100)

      contact = %{
        uid: "fold-gen@example.com",
        formatted_name: "Fold Test",
        notes: long_note
      }

      assert {:ok, vcard} = VCard.generate(contact)
      # Folded lines have CRLF followed by space
      lines = String.split(vcard, "\r\n")
      # Some lines should be continuation lines (starting with space)
      assert Enum.any?(lines, &String.starts_with?(&1, " "))
    end
  end

  describe "generate_uid/0" do
    test "generates unique UIDs" do
      uid1 = VCard.generate_uid()
      uid2 = VCard.generate_uid()

      assert uid1 != uid2
      assert String.ends_with?(uid1, "@elektrine.com")
      assert String.ends_with?(uid2, "@elektrine.com")
    end

    test "generates valid UUID format" do
      uid = VCard.generate_uid()
      # Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx@elektrine.com
      assert String.match?(
               uid,
               ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@elektrine\.com$/
             )
    end
  end

  describe "round-trip parsing and generation" do
    test "parse then generate preserves data" do
      original_vcard = """
      BEGIN:VCARD
      VERSION:3.0
      UID:roundtrip@example.com
      FN:Round Trip
      N:Trip;Round;;;
      EMAIL;TYPE=WORK:round@example.com
      TEL;TYPE=CELL:+1234567890
      ORG:Test Org
      END:VCARD
      """

      assert {:ok, parsed} = VCard.parse(original_vcard)
      assert {:ok, generated} = VCard.generate(parsed)

      # Parse the generated vCard
      assert {:ok, reparsed} = VCard.parse(generated)

      assert reparsed.uid == "roundtrip@example.com"
      assert reparsed.formatted_name == "Round Trip"
      assert reparsed.first_name == "Round"
      assert reparsed.last_name == "Trip"
      assert reparsed.organization == "Test Org"
    end
  end
end
