defmodule Xamal.Configuration.DeployQueueTest do
  use ExUnit.Case, async: true

  alias Xamal.Configuration.DeployQueue

  test "parses the queue settings" do
    queue =
      DeployQueue.new(%{"wait_timeout" => 60, "hold_timeout" => 120, "follow" => "origin/main"})

    assert queue == %DeployQueue{wait_timeout: 60, hold_timeout: 120, follow: "origin/main"}
  end

  test "waits half an hour, frees a held lock after an hour and follows nothing by default" do
    assert DeployQueue.new(%{}) == %DeployQueue{
             wait_timeout: 1800,
             hold_timeout: 3600,
             follow: nil
           }

    assert DeployQueue.new(nil) == DeployQueue.new(%{})
  end
end
