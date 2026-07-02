defmodule Elektrine.Social.Scrobble do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  alias Elektrine.Security.URLValidator

  @visibilities ~w(public unlisted followers private)

  schema "social_scrobbles" do
    field :title, :string
    field :artist, :string
    field :album, :string
    field :length, :integer
    field :external_link, :string
    field :visibility, :string, default: "public"

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(scrobble, attrs) do
    scrobble
    |> cast(attrs, [:user_id, :title, :artist, :album, :length, :external_link, :visibility])
    |> normalize_blank_strings([:title, :artist, :album, :external_link])
    |> validate_required([:user_id, :title, :visibility])
    |> validate_length(:title, min: 1, max: 300)
    |> validate_length(:artist, max: 300)
    |> validate_length(:album, max: 300)
    |> validate_number(:length, greater_than_or_equal_to: 0)
    |> validate_length(:external_link, max: 2_048)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_external_link()
    |> foreign_key_constraint(:user_id)
  end

  defp normalize_blank_strings(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      update_change(acc, field, fn
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> nil
            trimmed -> trimmed
          end

        value ->
          value
      end)
    end)
  end

  defp validate_external_link(changeset) do
    validate_change(changeset, :external_link, fn :external_link, value ->
      uri = URI.parse(value)

      cond do
        uri.scheme not in ["http", "https"] ->
          [external_link: "must be an http or https URL"]

        !is_binary(uri.host) or uri.host == "" ->
          [external_link: "must include a host"]

        URLValidator.private_ip?(uri.host) ->
          [external_link: "must be a public URL"]

        true ->
          []
      end
    end)
  end
end
