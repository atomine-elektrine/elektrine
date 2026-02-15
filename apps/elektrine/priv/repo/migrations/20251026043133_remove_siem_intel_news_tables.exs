defmodule Elektrine.Repo.Migrations.RemoveSiemIntelNewsTables do
  use Ecto.Migration

  def change do
    # Drop tables that depend on both SIEM and threat intel first
    drop_if_exists table(:threat_matches)
    drop_if_exists table(:news_threat_correlations)

    # Drop SIEM tables (children first)
    drop_if_exists table(:siem_alert_events)
    drop_if_exists table(:siem_incident_alerts)
    drop_if_exists table(:siem_incidents)
    drop_if_exists table(:siem_alerts)
    drop_if_exists table(:siem_events)
    drop_if_exists table(:siem_rules)
    drop_if_exists table(:siem_sources)
    drop_if_exists table(:siem_dashboards)

    # Drop ransomware tables (depends on threat_indicators)
    drop_if_exists table(:ransomware_indicators)
    drop_if_exists table(:ransomware_victims)
    drop_if_exists table(:ransomware_threats)
    drop_if_exists table(:ransomware_groups)

    # Drop threat intel tables
    drop_if_exists table(:threat_campaign_indicators)
    drop_if_exists table(:threat_campaigns)
    drop_if_exists table(:threat_indicators)
    drop_if_exists table(:threat_feeds)

    # Drop underground intel tables
    drop_if_exists table(:telegram_messages)
    drop_if_exists table(:telegram_channels)
    drop_if_exists table(:malware_servers)
    drop_if_exists table(:compromised_credentials)
    drop_if_exists table(:breached_databases)
    drop_if_exists table(:data_breaches)
    drop_if_exists table(:underground_forums)

    # Drop cybersec news tables
    drop_if_exists table(:cybersecurity_news)
    drop_if_exists table(:news_feeds)
  end
end
