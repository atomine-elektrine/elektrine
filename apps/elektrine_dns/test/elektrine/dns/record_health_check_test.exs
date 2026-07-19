defmodule Elektrine.DNS.RecordHealthCheckTest do
  use ExUnit.Case, async: true

  alias Elektrine.DNS.Record

  defp changeset(attrs) do
    Record.changeset(
      %Record{},
      Map.merge(
        %{
          "name" => "@",
          "type" => "A",
          "content" => "203.0.113.10",
          "ttl" => 300,
          "zone_id" => 1
        },
        attrs
      )
    )
  end

  test "enabling folds health_check into metadata with default port" do
    changeset = changeset(%{"health_check_enabled" => "true"})

    assert Ecto.Changeset.get_field(changeset, :metadata)["health_check"] == %{
             "enabled" => true,
             "port" => 443
           }
  end

  test "a valid custom port is stored" do
    changeset = changeset(%{"health_check_enabled" => "true", "health_check_port" => "8443"})

    assert get_in(Ecto.Changeset.get_field(changeset, :metadata), ["health_check", "port"]) ==
             8443
  end

  test "an out-of-range port falls back to the default" do
    changeset = changeset(%{"health_check_enabled" => "true", "health_check_port" => "99999"})

    refute changeset.valid?
  end

  test "disabling removes the metadata key" do
    record = %Record{metadata: %{"health_check" => %{"enabled" => true, "port" => 443}}}

    changeset =
      Record.changeset(record, %{
        "name" => "@",
        "type" => "A",
        "content" => "203.0.113.10",
        "ttl" => 300,
        "zone_id" => 1,
        "health_check_enabled" => "false"
      })

    refute Map.has_key?(Ecto.Changeset.get_field(changeset, :metadata), "health_check")
  end

  test "non-address types never gain health_check metadata" do
    changeset =
      changeset(%{
        "type" => "TXT",
        "content" => "hello",
        "health_check_enabled" => "true"
      })

    refute Map.has_key?(Ecto.Changeset.get_field(changeset, :metadata) || %{}, "health_check")
  end

  test "untouched forms leave existing metadata alone" do
    record = %Record{metadata: %{"health_check" => %{"enabled" => true, "port" => 443}}}

    changeset =
      Record.changeset(record, %{"ttl" => 600})

    assert get_in(Ecto.Changeset.get_field(changeset, :metadata), ["health_check", "enabled"]) ==
             true
  end

  test "readers expose enrollment and port" do
    record = %Record{metadata: %{"health_check" => %{"enabled" => true, "port" => 8443}}}

    assert Record.health_check?(record)
    assert Record.health_check_port(record) == 8443
    refute Record.health_check?(%Record{metadata: %{}})
    assert Record.health_check_port(%Record{metadata: %{}}) == nil
  end
end
