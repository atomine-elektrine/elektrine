defmodule Elektrine.Repo.Migrations.NormalizeInviteCodesCaseInsensitively do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE duplicate_codes text;
    BEGIN
      SELECT string_agg(normalized_code, ', ' ORDER BY normalized_code)
      INTO duplicate_codes
      FROM (
        SELECT upper(btrim(code)) AS normalized_code
        FROM invite_codes
        GROUP BY 1
        HAVING count(*) > 1
      ) duplicates;

      IF duplicate_codes IS NOT NULL THEN
        RAISE EXCEPTION
          'Cannot normalize invite codes because duplicate case-insensitive values already exist: %',
          duplicate_codes;
      END IF;
    END
    $$;
    """)

    execute("UPDATE invite_codes SET code = upper(btrim(code))")

    drop_if_exists(index(:invite_codes, [:code]))

    create(unique_index(:invite_codes, ["upper(code)"], name: :invite_codes_code_upper_unique))
  end

  def down do
    drop_if_exists(index(:invite_codes, ["upper(code)"], name: :invite_codes_code_upper_unique))
    create(unique_index(:invite_codes, [:code]))
  end
end
