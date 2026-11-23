defmodule Xamal.SSH.HostKeyCheckTest do
  # End to end through :ssh.connect against a loopback daemon that requires a
  # public key, for every way Xamal can sign: a key from ssh.keys or
  # ssh.key_data, an ssh-agent (ssh.agent), and :ssh's own key files.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Xamal.Configuration.Ssh

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup %{tmp_dir: dir} do
    system_dir = Path.join(dir, "system")
    daemon_users = Path.join(dir, "daemon_users")
    known = Path.join(dir, "known")
    Enum.each([system_dir, daemon_users, known], &File.mkdir_p!/1)

    keygen!(["-t", "ed25519", "-f", Path.join(system_dir, "ssh_host_ed25519_key")])
    client_key = Path.join(dir, "id_ed25519")
    keygen!(["-t", "ed25519", "-f", client_key])
    File.cp!(client_key <> ".pub", Path.join(daemon_users, "authorized_keys"))

    {:ok, daemon} =
      :ssh.daemon({127, 0, 0, 1}, 0,
        system_dir: String.to_charlist(system_dir),
        user_dir: String.to_charlist(daemon_users),
        auth_methods: ~c"publickey"
      )

    on_exit(fn -> :ssh.stop_daemon(daemon) end)
    {:ok, info} = :ssh.daemon_info(daemon)
    port = Keyword.fetch!(info, :port)
    host_pub = File.read!(Path.join(system_dir, "ssh_host_ed25519_key.pub"))

    %{port: port, client_key: client_key, known: known, host_pub: host_pub, dir: dir}
  end

  defp keygen!(args) do
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-N", ""] ++ args)
  end

  defp connect(ssh, known, port) do
    opts = Ssh.connect_options(ssh) |> Keyword.put(:user_dir, String.to_charlist(known))
    :ssh.connect(~c"127.0.0.1", port, opts, 10_000)
  end

  # :ssh says only "Key exchange failed", so the reason has to be printed.
  defp assert_refused(connect, port) do
    message = capture_io(:stderr, fn -> assert {:error, _reason} = connect.() end)
    assert message =~ "[127.0.0.1]:#{port} presented does not match"
    assert message =~ "ssh-keygen -R '[127.0.0.1]:#{port}'"
  end

  defp known_hosts(known), do: File.read!(Path.join(known, "known_hosts"))

  defp record!(known, line), do: File.write!(Path.join(known, "known_hosts"), line <> "\n")

  defp other_host_key(dir) do
    path = Path.join(dir, "other_host_key")
    keygen!(["-t", "ed25519", "-f", path])
    (path <> ".pub") |> File.read!() |> String.split() |> Enum.take(2) |> Enum.join(" ")
  end

  defp host_line(port, host_pub),
    do: "[127.0.0.1]:#{port} " <> (host_pub |> String.split() |> Enum.take(2) |> Enum.join(" "))

  describe "with a key from ssh.keys" do
    setup %{client_key: client_key} do
      %{ssh: Ssh.new(%{"user" => "deploy", "keys" => [client_key]})}
    end

    test "records a new host, then accepts it again", %{ssh: ssh, known: known, port: port} do
      assert {:ok, conn} = connect(ssh, known, port)
      :ssh.close(conn)
      assert known_hosts(known) =~ "[127.0.0.1]:#{port} ssh-ed25519 "

      assert {:ok, conn} = connect(ssh, known, port)
      :ssh.close(conn)
    end

    test "refuses a host whose key changed", %{ssh: ssh, known: known, port: port, dir: dir} do
      record!(known, "[127.0.0.1]:#{port} " <> other_host_key(dir))

      assert_refused(fn -> connect(ssh, known, port) end, port)
    end
  end

  describe "with ssh.agent" do
    setup %{client_key: client_key, dir: dir} do
      agent = System.find_executable("ssh-agent")
      if is_nil(agent), do: raise("ssh-agent is needed for these tests")

      # A short path, since a Unix socket path is capped near 104 bytes.
      socket = Path.join(System.tmp_dir!(), "xa#{System.unique_integer([:positive])}.sock")
      {out, 0} = System.cmd(agent, ["-a", socket, "-s"])
      [_, pid] = Regex.run(~r/SSH_AGENT_PID=(\d+)/, out)

      on_exit(fn ->
        System.cmd("kill", [pid])
        File.rm(socket)
      end)

      {_, 0} =
        System.cmd("ssh-add", [client_key],
          env: [{"SSH_AUTH_SOCK", socket}],
          stderr_to_stdout: true
        )

      # The key file is moved away so only the agent can sign.
      File.rename!(client_key, Path.join(dir, "moved_key"))
      %{ssh: Ssh.new(%{"user" => "deploy", "agent" => socket})}
    end

    test "signs through the agent and records a new host", %{ssh: ssh, known: known, port: port} do
      assert {:ok, conn} = connect(ssh, known, port)
      :ssh.close(conn)
      assert known_hosts(known) =~ "[127.0.0.1]:#{port} ssh-ed25519 "
    end

    test "accepts a host whose recorded key matches", %{ssh: ssh} = ctx do
      record!(ctx.known, host_line(ctx.port, ctx.host_pub))

      assert {:ok, conn} = connect(ssh, ctx.known, ctx.port)
      :ssh.close(conn)
    end

    test "refuses a host whose key changed", %{ssh: ssh, known: known, port: port, dir: dir} do
      record!(known, "[127.0.0.1]:#{port} " <> other_host_key(dir))

      assert_refused(fn -> connect(ssh, known, port) end, port)
    end
  end

  describe "with neither, :ssh's own key files" do
    setup %{client_key: client_key, known: known} do
      # :ssh_file looks for id_ed25519 in the user directory.
      File.cp!(client_key, Path.join(known, "id_ed25519"))
      %{ssh: Ssh.new(%{"user" => "deploy"})}
    end

    test "signs with the key file and refuses a changed host key", ctx do
      assert {:ok, conn} = connect(ctx.ssh, ctx.known, ctx.port)
      :ssh.close(conn)
      assert known_hosts(ctx.known) =~ "[127.0.0.1]:#{ctx.port} ssh-ed25519 "

      record!(ctx.known, "[127.0.0.1]:#{ctx.port} " <> other_host_key(ctx.dir))
      assert_refused(fn -> connect(ctx.ssh, ctx.known, ctx.port) end, ctx.port)
    end
  end
end
