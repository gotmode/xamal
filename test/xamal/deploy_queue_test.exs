defmodule Xamal.DeployQueueTest do
  use ExUnit.Case, async: true

  alias Xamal.DeployQueue

  test "split_lines keeps a partial last line for the next chunk" do
    assert DeployQueue.split_lines("XAMAL_QUEUE_WAITING a\r\nXAMAL_QUE") ==
             {["XAMAL_QUEUE_WAITING a"], "XAMAL_QUE"}

    assert DeployQueue.split_lines("UE_ACQUIRED\n") == {["UE_ACQUIRED"], ""}
  end
end
