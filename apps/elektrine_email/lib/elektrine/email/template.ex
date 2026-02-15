defmodule Elektrine.Email.Template do
  @moduledoc """
  Schema for email templates.
  Allows users to save reusable email templates.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "email_templates" do
    field :name, :string
    field :subject, :string
    field :body, :string
    field :html_body, :string

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @doc """
  Creates a changeset for an email template.
  """
  def changeset(template, attrs) do
    template
    |> cast(attrs, [:name, :subject, :body, :html_body, :user_id])
    |> validate_required([:name, :body, :user_id])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:subject, max: 500)
    |> validate_length(:body, min: 1, max: 50000)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :name])
  end
end
