defmodule Elektrine.Repo.Migrations.CreateSiemTables do
  use Ecto.Migration

  def change do
    # SIEM event sources - systems/applications generating events
    create table(:siem_sources) do
      add :name, :string, null: false
      # web, application, infrastructure, network, database
      add :type, :string, null: false
      add :description, :text
      add :active, :boolean, default: true
      # source-specific configuration
      add :config, :map, default: %{}
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:siem_sources, [:user_id])
    create index(:siem_sources, [:type])
    create unique_index(:siem_sources, [:user_id, :name])

    # SIEM events - raw security events collected from various sources
    create table(:siem_events) do
      # unique identifier from source
      add :event_id, :string, null: false
      add :timestamp, :utc_datetime, null: false
      # login, scan, attack, alert, etc.
      add :event_type, :string, null: false
      # critical, high, medium, low, info
      add :severity, :string, null: false
      add :source_ip, :string
      add :destination_ip, :string
      add :user_agent, :text
      add :method, :string
      add :url, :text
      add :status_code, :integer
      add :response_size, :integer
      add :response_time, :integer
      add :username, :string
      add :action, :string
      add :resource, :string
      # success, failure, blocked
      add :result, :string
      add :message, :text
      # original log entry
      add :raw_data, :text
      # additional structured data
      add :metadata, :map, default: %{}
      add :processed, :boolean, default: false
      add :correlated, :boolean, default: false
      add :source_id, references(:siem_sources, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:siem_events, [:source_id])
    create index(:siem_events, [:timestamp])
    create index(:siem_events, [:event_type])
    create index(:siem_events, [:severity])
    create index(:siem_events, [:source_ip])
    create index(:siem_events, [:username])
    create index(:siem_events, [:processed])
    create index(:siem_events, [:correlated])
    create unique_index(:siem_events, [:source_id, :event_id])

    # SIEM alerts - processed events that require attention
    create table(:siem_alerts) do
      add :title, :string, null: false
      add :description, :text
      add :severity, :string, null: false
      # anomaly, threshold, correlation, pattern
      add :alert_type, :string, null: false
      # open, investigating, resolved, false_positive
      add :status, :string, default: "open"
      # confidence score 0.0-1.0
      add :confidence, :float
      # calculated risk score
      add :risk_score, :float
      add :first_seen, :utc_datetime, null: false
      add :last_seen, :utc_datetime, null: false
      add :event_count, :integer, default: 1
      add :source_ips, {:array, :string}, default: []
      add :affected_users, {:array, :string}, default: []
      add :affected_resources, {:array, :string}, default: []
      add :tags, {:array, :string}, default: []
      add :assignee_id, references(:users, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime
      add :resolution_notes, :text
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:siem_alerts, [:user_id])
    create index(:siem_alerts, [:severity])
    create index(:siem_alerts, [:status])
    create index(:siem_alerts, [:alert_type])
    create index(:siem_alerts, [:first_seen])
    create index(:siem_alerts, [:assignee_id])

    # Junction table linking alerts to events
    create table(:siem_alert_events) do
      add :alert_id, references(:siem_alerts, on_delete: :delete_all), null: false
      add :event_id, references(:siem_events, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:siem_alert_events, [:alert_id, :event_id])

    # SIEM rules - detection rules for generating alerts
    create table(:siem_rules) do
      add :name, :string, null: false
      add :description, :text
      # threshold, correlation, anomaly, pattern
      add :rule_type, :string, null: false
      add :severity, :string, null: false
      add :active, :boolean, default: true
      # rule logic and conditions
      add :conditions, :map, null: false
      # for threshold rules
      add :threshold_count, :integer
      # time window in seconds
      add :threshold_window, :integer
      # suppression period in seconds
      add :suppression_window, :integer
      add :tags, {:array, :string}, default: []
      add :mitre_tactics, {:array, :string}, default: []
      add :mitre_techniques, {:array, :string}, default: []
      add :last_triggered, :utc_datetime
      add :trigger_count, :integer, default: 0
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:siem_rules, [:user_id])
    create index(:siem_rules, [:active])
    create index(:siem_rules, [:rule_type])
    create index(:siem_rules, [:severity])
    create unique_index(:siem_rules, [:user_id, :name])

    # SIEM dashboards - custom dashboards for monitoring
    create table(:siem_dashboards) do
      add :name, :string, null: false
      add :description, :text
      # dashboard layout and widgets
      add :config, :map, null: false
      add :is_default, :boolean, default: false
      add :shared, :boolean, default: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:siem_dashboards, [:user_id])
    create index(:siem_dashboards, [:shared])
    create unique_index(:siem_dashboards, [:user_id, :name])

    # SIEM incidents - grouped alerts representing security incidents
    create table(:siem_incidents) do
      add :title, :string, null: false
      add :description, :text
      add :severity, :string, null: false
      # open, investigating, contained, resolved
      add :status, :string, default: "open"
      # data_breach, malware, dos_attack, etc.
      add :incident_type, :string
      add :first_detected, :utc_datetime, null: false
      add :last_activity, :utc_datetime, null: false
      # low, medium, high, critical
      add :estimated_impact, :string
      add :affected_systems, {:array, :string}, default: []
      add :affected_users, {:array, :string}, default: []
      add :response_actions, :text
      add :lessons_learned, :text
      add :assignee_id, references(:users, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create index(:siem_incidents, [:user_id])
    create index(:siem_incidents, [:severity])
    create index(:siem_incidents, [:status])
    create index(:siem_incidents, [:first_detected])
    create index(:siem_incidents, [:assignee_id])

    # Junction table linking incidents to alerts
    create table(:siem_incident_alerts) do
      add :incident_id, references(:siem_incidents, on_delete: :delete_all), null: false
      add :alert_id, references(:siem_alerts, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:siem_incident_alerts, [:incident_id, :alert_id])
  end
end
