Code.require_file("../module_selection.exs", __DIR__)

import Config

selected_modules = ElektrineReleaseBuilder.ModuleSelection.selected_modules()
selected_module_set = MapSet.new(selected_modules)

module_selected? = fn module_id ->
  MapSet.member?(selected_module_set, module_id)
end

import_config "../../config/config.exs"

config :elektrine,
  compiled_platform_modules: selected_modules,
  platform_modules: [enabled: selected_modules]

oban_config = Application.get_env(:elektrine, Oban, [])

filtered_queues =
  oban_config
  |> Keyword.get(:queues, [])
  |> Enum.reject(fn
    {:email, _} -> not module_selected?.(:email)
    {:email_inbound, _} -> not module_selected?.(:email)
    {:activitypub, _} -> not module_selected?.(:social)
    {:activitypub_delivery, _} -> not module_selected?.(:social)
    {:federation, _} -> not module_selected?.(:social)
    {:federation_metadata, _} -> not module_selected?.(:social)
    {:messaging_federation, _} -> not module_selected?.(:chat)
    _ -> false
  end)

filtered_plugins =
  oban_config
  |> Keyword.get(:plugins, [])
  |> Enum.map(fn
    {Oban.Plugins.Cron, cron_opts} ->
      filtered_crontab =
        cron_opts
        |> Keyword.get(:crontab, [])
        |> Enum.reject(fn
          {_expr, Elektrine.Bluesky.InboundPollWorker} ->
            not module_selected?.(:social)

          {_expr, Elektrine.ActivityPub.RefreshCountsWorker, _args} ->
            not module_selected?.(:social)

          {_expr, Elektrine.Jobs.RecalculateRecentDiscussionScoresWorker} ->
            not module_selected?.(:social)

          {_expr, Elektrine.Jobs.EmailRecategorizer} ->
            not module_selected?.(:email)

          {_expr, Elektrine.Jobs.ReplyLaterProcessor} ->
            not module_selected?.(:email)

          _ ->
            false
        end)

      {Oban.Plugins.Cron, Keyword.put(cron_opts, :crontab, filtered_crontab)}

    plugin ->
      plugin
  end)

config :elektrine,
       Oban,
       oban_config
       |> Keyword.put(:queues, filtered_queues)
       |> Keyword.put(:plugins, filtered_plugins)
