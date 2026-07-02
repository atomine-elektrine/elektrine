defmodule Elektrine.Repo.Migrations.AddBirthdayFieldsToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :birthday, :date
      add :show_birthday, :boolean, default: false, null: false
    end

    execute("""
    CREATE INDEX users_visible_birthday_month_day_idx
    ON users ((date_part('month', birthday)), (date_part('day', birthday)))
    WHERE show_birthday = true AND birthday IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS users_visible_birthday_month_day_idx")

    alter table(:users) do
      remove :show_birthday
      remove :birthday
    end
  end
end
