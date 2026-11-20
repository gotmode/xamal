defmodule Xamal.DeployLock do
  @moduledoc false

  import Xamal.Output
  import Xamal.Remote

  alias Xamal.Commands.Lock
  alias Xamal.Context
  alias Xamal.LocalIdentity

  # Longer than any boot, health check and drain, the part of a deploy the
  # lock covers.
  @stale_lock_seconds 900
  @stale_lock_poll 10

  @spec with_lock(Context.t(), (-> result) | (Context.t() -> result)) :: result
        when result: term()
  def with_lock(%Context{} = context, fun) when is_function(fun) do
    if context.holding_lock do
      invoke(fun, context)
    else
      acquire_lock(context)
      locked_context = Context.put_holding_lock(context, true)

      try do
        invoke(fun, locked_context)
      after
        safe_release_lock(context)
      end
    end
  end

  defp invoke(fun, context) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 1} -> fun.(context)
      {:arity, 0} -> fun.()
    end
  end

  defp acquire_lock(context, retried \\ false) do
    config = context.config

    say("Acquiring the deploy lock...", :magenta)
    on_primary(Lock.ensure_locks_directory(config), context)

    case on_primary(lock_command(config), context) do
      {:ok, _} ->
        :ok

      {:error, {:ssh_connection_failed, hostname, port, reason}} ->
        say("SSH connection failed to #{hostname}:#{port} (#{reason})", :red)
        say("Verify the host is reachable and SSH is running.", :red)
        raise "SSH connection failed to #{hostname}:#{port}"

      {:error, _reason} ->
        if context.holding_queue and not retried and automatic_lock_cleared?(context) do
          acquire_lock(context, true)
        else
          say("Deploy lock already in place!", :red)
          print_lock_status(context)
          raise "Deploy lock found. Run 'mix xamal.lock.status' for more information"
        end
    end
  end

  # A deploy holding the deploy queue is the only one past it, so a lock
  # another deploy took on its own was either left by a deploy that was
  # interrupted, or belongs to one run by an older Xamal that does not queue.
  # Wait out the second kind, clear the first. A lock taken by hand
  # (`mix xamal.lock.acquire`) still stops the deploy.
  defp automatic_lock_cleared?(context, waited \\ 0) do
    case on_primary(Lock.automatic_lock_age(context.config), context) do
      {:ok, age} ->
        case Integer.parse(age) do
          {seconds, _} when seconds >= @stale_lock_seconds ->
            say("Clearing a deploy lock an interrupted deploy left #{seconds}s ago", :yellow)
            on_primary(Lock.release(context.config), context)
            true

          {_seconds, _} when waited < @stale_lock_seconds ->
            say("  Another deploy is booting a release, waiting for it...", :yellow)
            Process.sleep(@stale_lock_poll * 1000)
            automatic_lock_cleared?(context, waited + @stale_lock_poll)

          _ ->
            false
        end

      {:error, {:exit_status, _, _}} ->
        # Gone since the failed acquire, or taken by hand.
        lock_gone?(context)

      {:error, _} ->
        false
    end
  end

  defp lock_gone?(context) do
    match?({:error, _}, on_primary(Lock.status(context.config), context))
  end

  defp lock_command(config) do
    Lock.acquire(
      config,
      "Automatic deploy lock",
      config.version,
      LocalIdentity.git_user_name(),
      DateTime.utc_now() |> DateTime.to_iso8601()
    )
  end

  defp print_lock_status(context) do
    case on_primary(Lock.status(context.config), context) do
      {:ok, output} -> IO.puts(output)
      _ -> :ok
    end
  end

  defp safe_release_lock(context) do
    release_lock(context)
  rescue
    exception -> say("Error releasing deploy lock: #{Exception.message(exception)}", :red)
  end

  defp release_lock(context) do
    say("Releasing the deploy lock...", :magenta)
    on_primary(Lock.release(context.config), context)
  end
end
