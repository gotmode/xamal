defmodule Xamal.Commands.DeployQueue do
  @moduledoc """
  The shell script that holds a service's deploy queue lock on its primary
  host.

  The lock is `flock(1)` on a file, held by a shell that lives exactly as long
  as the SSH session that started it. The shell takes the lock, says so, then
  blocks reading its stdin. When the deploy ends, fails, is interrupted or its
  machine drops off the network, the session closes, the read sees EOF, the
  shell exits and the kernel frees the lock. Nothing has to clean up after a
  crash, unlike the `mkdir` lock. `timeout` bounds the hold, so a session the
  host never sees close (a laptop that slept mid-deploy) frees the lock after
  `hold_timeout` seconds at the latest.

  The script speaks in lines the caller reads:

    * `XAMAL_QUEUE_WAITING <details>`, another deploy holds the lock, with
      that deploy's own details line
    * `XAMAL_QUEUE_STILL <seconds>`, still waiting
    * `XAMAL_QUEUE_ACQUIRED`, this deploy holds the lock
    * `XAMAL_QUEUE_TIMEOUT`, gave up after `wait_timeout`, exit status 75
  """

  alias Xamal.Configuration
  alias Xamal.Configuration.DeployQueue

  @poll_seconds 60

  @spec hold(Configuration.t(), String.t()) :: String.t()
  def hold(%Configuration{} = config, details) do
    queue = config.deploy_queue || %DeployQueue{}
    lock = remote_path(Configuration.deploy_queue_lock(config))
    details = details |> String.replace(~r/[\r\n]+/, " ") |> Xamal.Utils.shell_escape()

    """
    lock=#{lock}; info="$lock.info"
    mkdir -p "$(dirname "$lock")" || exit 1
    exec 9>>"$lock" || exit 1
    if ! flock -n 9; then
      echo "XAMAL_QUEUE_WAITING $(cat "$info" 2>/dev/null)"
      waited=0
      until flock -w #{@poll_seconds} 9; do
        waited=$((waited + #{@poll_seconds}))
        if [ "$waited" -ge #{queue.wait_timeout} ]; then echo XAMAL_QUEUE_TIMEOUT; exit 75; fi
        echo "XAMAL_QUEUE_STILL $waited"
      done
    fi
    printf '%s\\n' #{details} > "$info"
    echo XAMAL_QUEUE_ACQUIRED
    timeout #{queue.hold_timeout} cat > /dev/null
    """
  end

  # `~/` in a double-quoted shell word does not expand.
  defp remote_path("~/" <> rest), do: "\"$HOME/#{rest}\""
  defp remote_path(path), do: Xamal.Utils.shell_escape(path)
end
