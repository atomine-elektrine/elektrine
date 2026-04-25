defmodule Elektrine.Messaging.FederationErrorsTest do
  use ExUnit.Case, async: true

  alias Elektrine.Messaging.Federation.Errors

  test "maps expanded federation policy errors" do
    assert Errors.error_code(:rate_limited) == "rate_limited"
    assert Errors.error_code(:peer_quarantined) == "peer_quarantined"
    assert Errors.error_code(:peer_blocked) == "peer_blocked"
    assert Errors.error_code(:event_too_large) == "event_too_large"
    assert Errors.error_code(:batch_too_large) == "batch_too_large"
    assert Errors.error_code(:snapshot_too_large) == "snapshot_too_large"
    assert Errors.error_code(:cursor_expired) == "cursor_expired"
    assert Errors.error_code(:media_not_authorized) == "media_not_authorized"
  end
end
