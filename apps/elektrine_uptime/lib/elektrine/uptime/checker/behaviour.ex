defmodule Elektrine.Uptime.Checker.Behaviour do
  @moduledoc """
  Behaviour for probing a monitor target.

  Implementations probe the monitor (HTTP/TCP/ping) and report whether it is up
  or down. The whole checker is swappable in tests via
  `Application.get_env(:elektrine_uptime, :checker, Elektrine.Uptime.Checker)`.
  """

  alias Elektrine.Uptime.Monitor

  @type up_result :: {:up, %{response_time_ms: non_neg_integer(), status_code: integer() | nil}}
  @type down_result :: {:down, String.t()}
  @type result :: up_result() | down_result()

  @callback run(Monitor.t()) :: result()
end
