defmodule Xamal.Commands.DeployQueueTest do
  use ExUnit.Case, async: true

  alias Xamal.Commands.DeployQueue
  alias Xamal.Configuration.DeployQueue, as: QueueConfig

  @config %Xamal.Configuration{
    raw_config: %{"service" => "my-app"},
    deploy_queue: %QueueConfig{wait_timeout: 600, hold_timeout: 1200}
  }

  test "holds flock on the service's lock file in the deployer's home" do
    script = DeployQueue.hold(@config, "Jon on mac, version abc123")

    assert script =~ ~s(lock="$HOME/.xamal/deploy-my-app.lock")
    assert script =~ "exec 9>>\"$lock\""
    assert script =~ "flock -n 9"
    assert script =~ "flock -w 60 9"
  end

  test "gives up after wait_timeout and frees the lock after hold_timeout" do
    script = DeployQueue.hold(@config, "x")

    assert script =~ ~s(-ge 600 ]; then echo XAMAL_QUEUE_TIMEOUT; exit 75)
    assert script =~ "timeout 1200 cat > /dev/null"
  end

  test "says when it waits, with the running deploy's details, and when it holds the lock" do
    script = DeployQueue.hold(@config, "x")

    assert script =~ ~s|echo "XAMAL_QUEUE_WAITING $(cat "$info" 2>/dev/null)"|
    assert script =~ "echo XAMAL_QUEUE_ACQUIRED"
  end

  test "writes the details as one quoted line" do
    script = DeployQueue.hold(@config, "it's\nme")

    assert script =~ "printf '%s\\n' 'it'\\''s me' > \"$info\""
  end

  test "uses the default timeouts when the config has no queue section" do
    script = DeployQueue.hold(%{@config | deploy_queue: nil}, "x")

    assert script =~ "-ge 1800 ]"
    assert script =~ "timeout 3600 cat"
  end

  # Runs the script for real, where flock(1) exists (Linux, not macOS).
  @tag :flock
  test "a second holder waits for the first and holds the lock once the first ends" do
    home = Path.join(System.tmp_dir!(), "xamal-queue-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    first = open_holder(home, "first")
    assert_receive {^first, {:data, "XAMAL_QUEUE_ACQUIRED\n"}}, 5_000

    second = open_holder(home, "second")
    assert_receive {^second, {:data, "XAMAL_QUEUE_WAITING first\n"}}, 5_000
    refute_receive {^second, {:data, "XAMAL_QUEUE_ACQUIRED\n"}}, 500

    # Closing the session is the release, nothing else.
    Port.close(first)
    assert_receive {^second, {:data, "XAMAL_QUEUE_ACQUIRED\n"}}, 5_000
    Port.close(second)
  end

  defp open_holder(home, details) do
    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      env: [{~c"HOME", String.to_charlist(home)}],
      args: ["-c", DeployQueue.hold(@config, details)]
    ])
  end
end
