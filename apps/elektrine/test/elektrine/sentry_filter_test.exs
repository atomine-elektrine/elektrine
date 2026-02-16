defmodule Elektrine.SentryFilterTest do
  use ExUnit.Case, async: true

  alias Elektrine.SentryFilter

  test "drops benign http2 end stream mismatch errors" do
    event = %{
      original_exception: %Bandit.HTTP2.Errors.StreamError{
        message: "Received END_STREAM with byte still pending"
      }
    }

    assert SentryFilter.filter_event(event) == nil
  end

  test "keeps unrelated http2 stream errors" do
    event = %{
      original_exception: %Bandit.HTTP2.Errors.StreamError{
        message: "Some other stream error"
      }
    }

    assert SentryFilter.filter_event(event) == event
  end
end
