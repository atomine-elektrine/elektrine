defmodule Elektrine.Repo.Migrations.AddCybersecurityNews do
  use Ecto.Migration

  def change do
    # Cybersecurity news articles
    create table(:cybersecurity_news) do
      add :title, :string, null: false
      add :summary, :text
      add :content, :text
      add :url, :string, null: false
      add :published_at, :utc_datetime, null: false
      # "bleepingcomputer", "krebsonsecurity", etc.
      add :source, :string, null: false
      add :author, :string
      # "data_breach", "malware", "ransomware", "vulnerability", etc.
      add :category, :string
      # "critical", "high", "medium", "low", "info"
      add :severity, :string
      add :tags, {:array, :string}, default: []
      # threat actors/malware mentioned
      add :mentioned_threats, {:array, :string}, default: []
      # CVEs mentioned in article
      add :mentioned_cves, {:array, :string}, default: []
      # companies mentioned
      add :mentioned_companies, {:array, :string}, default: []
      # "positive", "negative", "neutral"
      add :sentiment, :string
      # how relevant to security operations (0.0-1.0)
      add :relevance_score, :float
      # unread, read, bookmarked
      add :read_status, :string, default: "unread"
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:cybersecurity_news, [:user_id])
    create index(:cybersecurity_news, [:published_at])
    create index(:cybersecurity_news, [:source])
    create index(:cybersecurity_news, [:category])
    create index(:cybersecurity_news, [:severity])
    create index(:cybersecurity_news, [:read_status])
    create index(:cybersecurity_news, [:relevance_score])
    create unique_index(:cybersecurity_news, [:user_id, :url])

    # News feeds configuration
    create table(:news_feeds) do
      add :name, :string, null: false
      # RSS/API URL
      add :url, :string, null: false
      # "rss", "api", "json"
      add :type, :string, null: false
      add :description, :text
      add :active, :boolean, default: true
      # 30 minutes
      add :update_frequency, :integer, default: 1800
      add :last_updated, :utc_datetime
      add :last_sync_status, :string, default: "pending"
      # feed-specific configuration
      add :config, :map, default: %{}
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:news_feeds, [:user_id])
    create index(:news_feeds, [:type])
    create index(:news_feeds, [:active])
    create unique_index(:news_feeds, [:user_id, :name])

    # News-threat correlations - link news articles to threat indicators
    create table(:news_threat_correlations) do
      # "mention", "analysis", "attribution"
      add :correlation_type, :string, null: false
      # correlation confidence
      add :confidence, :float
      # how they're related
      add :context, :text
      add :news_id, references(:cybersecurity_news, on_delete: :delete_all), null: false
      add :indicator_id, references(:threat_indicators, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:news_threat_correlations, [:news_id])
    create index(:news_threat_correlations, [:indicator_id])
    create index(:news_threat_correlations, [:correlation_type])
    create unique_index(:news_threat_correlations, [:news_id, :indicator_id])
  end
end
