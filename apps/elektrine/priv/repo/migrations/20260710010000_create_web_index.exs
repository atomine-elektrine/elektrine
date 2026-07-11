defmodule Elektrine.Repo.Migrations.CreateWebIndex do
  use Ecto.Migration

  def up do
    create table(:web_index_hosts, primary_key: false) do
      add :host, :string, primary_key: true
      add :robots_url, :text
      add :robots_body, :text
      add :robots_fetched_at, :utc_datetime_usec
      add :next_allowed_at, :utc_datetime_usec
      add :crawl_delay_ms, :integer, null: false, default: 1_000

      timestamps(type: :utc_datetime_usec)
    end

    create table(:web_index_documents) do
      add :url, :text, null: false
      add :canonical_url, :text, null: false
      add :host, references(:web_index_hosts, column: :host, type: :string), null: false
      add :discovered_from, :text
      add :depth, :integer, null: false, default: 0
      add :status, :string, null: false, default: "pending"
      add :title, :text
      add :description, :text
      add :content, :text
      add :content_hash, :binary
      add :language, :string
      add :http_status, :integer
      add :attempts, :integer, null: false, default: 0
      add :fetched_at, :utc_datetime_usec
      add :next_fetch_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:web_index_documents, [:canonical_url])
    create index(:web_index_documents, [:host, :status])
    create index(:web_index_documents, [:status, :next_fetch_at])
    create index(:web_index_documents, [:content_hash])

    execute("""
    ALTER TABLE web_index_documents
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('english', coalesce(description, '')), 'B') ||
      setweight(to_tsvector('english', coalesce(content, '')), 'C')
    ) STORED
    """)

    execute("""
    CREATE INDEX web_index_documents_search_vector_index
    ON web_index_documents USING GIN (search_vector)
    """)
  end

  def down do
    drop table(:web_index_documents)
    drop table(:web_index_hosts)
  end
end
