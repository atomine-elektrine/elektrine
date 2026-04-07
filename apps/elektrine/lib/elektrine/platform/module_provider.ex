defmodule Elektrine.Platform.ModuleProvider do
  @moduledoc false

  @callback core_children() :: [Supervisor.child_spec() | module() | tuple()]
  @callback web_children() :: [Supervisor.child_spec() | module() | tuple()]
  @callback mail_children() :: [Supervisor.child_spec() | module() | tuple()]
  @callback optional_delegate(atom()) :: module() | nil
  @callback send_vpn_quota_notification(atom(), list()) :: term()

  @optional_callbacks web_children: 0,
                      mail_children: 0,
                      optional_delegate: 1,
                      send_vpn_quota_notification: 2
end
