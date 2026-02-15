defmodule Elektrine.Email.Templates do
  @moduledoc """
  Context module for managing email templates.
  """
  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Email.Template

  @max_templates_per_user 50

  @doc """
  Lists all templates for a user.
  """
  def list_templates(user_id) do
    Template
    |> where(user_id: ^user_id)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Gets a template by ID for a user.
  """
  def get_template(id, user_id) do
    Template
    |> where(id: ^id, user_id: ^user_id)
    |> Repo.one()
  end

  @doc """
  Gets a template by name for a user.
  """
  def get_template_by_name(name, user_id) do
    Template
    |> where(user_id: ^user_id, name: ^name)
    |> Repo.one()
  end

  @doc """
  Creates a template.
  """
  def create_template(attrs) do
    user_id = Map.get(attrs, :user_id) || Map.get(attrs, "user_id")

    if count_templates(user_id) >= @max_templates_per_user do
      {:error, :limit_reached}
    else
      %Template{}
      |> Template.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Updates a template.
  """
  def update_template(%Template{} = template, attrs) do
    template
    |> Template.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a template.
  """
  def delete_template(%Template{} = template) do
    Repo.delete(template)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking template changes.
  """
  def change_template(%Template{} = template, attrs \\ %{}) do
    Template.changeset(template, attrs)
  end

  @doc """
  Counts templates for a user.
  """
  def count_templates(user_id) do
    Template
    |> where(user_id: ^user_id)
    |> select(count())
    |> Repo.one()
  end

  @doc """
  Duplicates a template with a new name.
  """
  def duplicate_template(%Template{} = template, new_name) do
    create_template(%{
      user_id: template.user_id,
      name: new_name,
      subject: template.subject,
      body: template.body,
      html_body: template.html_body
    })
  end
end
