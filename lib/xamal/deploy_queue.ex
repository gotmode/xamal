defmodule Xamal.DeployQueue do
  @moduledoc """
  Runs one deploy of a service at a time, whichever machine starts it.

  A deploy takes the queue lock on the primary host before it builds anything
  and keeps it until it is done. A second deploy started meanwhile, from this
  machine or any other, waits for the first instead of failing, then runs.
  `Xamal.Commands.DeployQueue` has the lock itself and why a crashed or
  interrupted deploy can never leave it behind.

  The lock lives on its own SSH connection, held by a separate process, so the
  deploy's own commands never wait behind it and closing that one connection
  is all a release takes.
  """

  import Xamal.Output

  alias Xamal.Commands.DeployQueue, as: Command
  alias Xamal.Configuration
  alias Xamal.Configuration.{DeployQueue, Ssh}
  alias Xamal.Context
  alias Xamal.LocalIdentity
  alias Xamal.SSH.{Host, Proxy}

  @release_timeout 10_000

  @doc """
  Run `fun` holding the deploy queue lock. `fun` gets the context and whether
  this deploy had to wait for another one. Nested calls run `fun` at once.
  """
  @spec with_queue(Context.t(), (Context.t(), boolean() -> result)) :: result when result: term()
  def with_queue(%Context{holding_queue: true} = context, fun), do: fun.(context, false)

  def with_queue(%Context{} = context, fun) do
    holder = acquire!(context)

    try do
      fun.(Context.put_holding_queue(context, true), holder.waited)
    after
      release(holder, context.config)
    end
  end

  defp acquire!(context) do
    config = context.config
    queue = config.deploy_queue || %DeployQueue{}
    host = Context.primary_host(context)
    script = Command.hold(config, details(config))
    parent = self()
    ref = make_ref()

    pid = spawn(fn -> hold(parent, ref, host, config.ssh, script) end)
    monitor = Process.monitor(pid)
    holder = %{pid: pid, ref: ref, monitor: monitor, waited: false}

    say("Joining the deploy queue for #{Configuration.service(config)}...", :magenta)
    # The script gives up on its own after wait_timeout. This only covers a
    # session that stops answering.
    await(holder, queue, (queue.wait_timeout + 120) * 1000)
  end

  defp details(config) do
    {:ok, local_host} = :inet.gethostname()

    "#{LocalIdentity.git_user_name()} on #{local_host}, version #{config.version}, " <>
      "since #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}"
  end

  defp await(%{ref: ref, monitor: monitor} = holder, queue, timeout) do
    receive do
      {^ref, {:line, "XAMAL_QUEUE_ACQUIRED"}} ->
        say("Holding the deploy queue", :magenta)
        holder

      {^ref, {:line, "XAMAL_QUEUE_WAITING" <> who}} ->
        say(waiting_message(String.trim(who), queue), :yellow)
        await(%{holder | waited: true}, queue, timeout)

      {^ref, {:line, "XAMAL_QUEUE_STILL " <> seconds}} ->
        say("  Still waiting for the deploy ahead (#{seconds}s)...", :yellow)
        await(holder, queue, timeout)

      {^ref, {:line, "XAMAL_QUEUE_TIMEOUT"}} ->
        stop(holder)

        raise "Gave up after waiting #{div(queue.wait_timeout, 60)} minutes for the deploy ahead. " <>
                "Check it with 'mix xamal.audit' and run this deploy again."

      {^ref, {:line, line}} ->
        IO.puts(line)
        await(holder, queue, timeout)

      {^ref, {:error, {:ssh_connection_failed, hostname, port, reason}}} ->
        say("SSH connection failed to #{hostname}:#{port} (#{inspect(reason)})", :red)
        raise "SSH connection failed to #{hostname}:#{port}"

      {^ref, {:closed, status}} ->
        raise "Could not take the deploy queue lock (exit status #{inspect(status)})"

      {:DOWN, ^monitor, :process, _pid, reason} ->
        raise "Could not take the deploy queue lock: #{inspect(reason)}"
    after
      timeout ->
        stop(holder)
        raise "Timed out joining the deploy queue"
    end
  end

  defp waiting_message("", queue) do
    "Another deploy is running. Waiting for it to finish (up to #{div(queue.wait_timeout, 60)} minutes)..."
  end

  defp waiting_message(who, queue) do
    "Another deploy is running (#{who}). Waiting for it to finish " <>
      "(up to #{div(queue.wait_timeout, 60)} minutes)..."
  end

  defp release(%{ref: ref, monitor: monitor} = holder, config) do
    receive do
      {^ref, {:closed, _status}} ->
        queue = config.deploy_queue || %DeployQueue{}

        say(
          "The deploy queue lock expired before this deploy finished (hold_timeout is #{queue.hold_timeout}s)",
          :yellow
        )
    after
      0 ->
        send(holder.pid, {:release, ref})

        receive do
          {^ref, :released} -> say("Left the deploy queue", :magenta)
          {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
        after
          @release_timeout -> stop(holder)
        end
    end

    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp stop(%{pid: pid, monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    Process.exit(pid, :kill)
  end

  # The process that owns the lock's SSH connection. It ends, and the
  # connection with it, when the deploy releases the lock or itself ends.
  defp hold(parent, ref, host, ssh, script) do
    parent_monitor = Process.monitor(parent)
    hostname = Host.hostname(host)
    port = Host.port(host, ssh)
    opts = Ssh.connect_options(ssh)

    case Proxy.connect(hostname, port, opts, Keyword.get(opts, :connect_timeout, 15_000)) do
      {:ok, conn, cleanup} ->
        try do
          {:ok, channel} = :ssh_connection.session_channel(conn, 30_000)
          :success = :ssh_connection.exec(conn, channel, String.to_charlist(script), 30_000)

          hold_loop(
            %{parent: parent, ref: ref, conn: conn, channel: channel, monitor: parent_monitor},
            ""
          )
        after
          :ssh.close(conn)
          cleanup.()
        end

      {:error, reason} ->
        send(parent, {ref, {:error, {:ssh_connection_failed, hostname, port, reason}}})
    end
  end

  defp hold_loop(%{conn: conn, channel: channel, ref: ref, parent: parent} = state, buffer) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, _type, data}} ->
        {lines, rest} = split_lines(buffer <> to_string(data))
        Enum.each(lines, &send(parent, {ref, {:line, &1}}))
        hold_loop(state, rest)

      {:ssh_cm, ^conn, {:exit_status, ^channel, status}} ->
        send(parent, {ref, {:closed, status}})

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        send(parent, {ref, {:closed, nil}})

      {:ssh_cm, ^conn, _other} ->
        hold_loop(state, buffer)

      {:release, ^ref} ->
        :ssh_connection.send_eof(conn, channel)
        :ssh_connection.close(conn, channel)
        send(parent, {ref, :released})

      {:DOWN, monitor, :process, _pid, _reason} when monitor == state.monitor ->
        :ok
    end
  end

  @doc false
  def split_lines(text) do
    [rest | lines] = text |> String.split("\n") |> Enum.reverse()
    {lines |> Enum.reverse() |> Enum.map(&String.trim_trailing(&1, "\r")), rest}
  end
end
