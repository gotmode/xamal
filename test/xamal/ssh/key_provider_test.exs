defmodule Xamal.SSH.KeyProviderTest do
  use ExUnit.Case, async: true

  alias Xamal.SSH.KeyProvider

  @moduletag :tmp_dir

  # ssh-keygen writes the OpenSSH format ("BEGIN OPENSSH PRIVATE KEY") by
  # default, which :public_key alone can't read.
  defp generate_key(dir, type) do
    path = Path.join(dir, "key_#{type}")
    {_, 0} = System.cmd("ssh-keygen", ["-q", "-t", type, "-N", "", "-f", path])
    File.read!(path)
  end

  test "reads an OpenSSH-format ed25519 key", %{tmp_dir: dir} do
    key_data = generate_key(dir, "ed25519")
    assert key_data =~ "BEGIN OPENSSH PRIVATE KEY"

    assert {:ok, _key} =
             KeyProvider.user_key(:"ssh-ed25519", key_cb_private: [key_data: key_data])
  end

  test "reads an OpenSSH-format RSA key", %{tmp_dir: dir} do
    key_data = generate_key(dir, "rsa")

    assert {:ok, _key} =
             KeyProvider.user_key(:"rsa-sha2-256", key_cb_private: [key_data: key_data])
  end

  test "reports no key for a different algorithm", %{tmp_dir: dir} do
    key_data = generate_key(dir, "ed25519")

    assert KeyProvider.user_key(:"ssh-rsa", key_cb_private: [key_data: key_data]) ==
             {:error, :no_matching_key}
  end

  test "reports no key for unreadable data" do
    assert KeyProvider.user_key(:"ssh-ed25519", key_cb_private: [key_data: "not a key"]) ==
             {:error, :no_matching_key}
  end

  describe "host keys" do
    # Host keys are made in-process, so these tests need no ssh-keygen.
    defp host_key(:ed25519), do: public({:namedCurve, :ed25519})
    defp host_key(:ecdsa), do: public({:namedCurve, :secp256r1})
    defp host_key(:rsa), do: public({:rsa, 2048, 65_537})

    defp public(params),
      do: params |> :public_key.generate_key() |> :ssh_file.extract_public_key()

    defp line(key) do
      [{key, []}] |> :ssh_file.encode(:openssh_key) |> IO.iodata_to_binary() |> String.trim()
    end

    defp hashed(name) do
      salt = :crypto.strong_rand_bytes(20)
      "|1|#{Base.encode64(salt)}|#{Base.encode64(:crypto.mac(:hmac, :sha, salt, name))}"
    end

    defp known_hosts(dir, lines) do
      File.write!(Path.join(dir, "known_hosts"), Enum.join(lines, "\n") <> "\n")
      [user_dir: String.to_charlist(dir)]
    end

    defp check(key, host, port, opts) do
      quietly(fn ->
        KeyProvider.is_host_key(key, [String.to_charlist(host)], port, :unused, opts)
      end)
    end

    # A refusal prints why on stderr, which these tests do not need to see.
    defp quietly(fun) do
      {result, _stderr} = ExUnit.CaptureIO.with_io(:stderr, fun)
      result
    end

    test "a host seen for the first time is not known yet", %{tmp_dir: dir} do
      key = host_key(:ed25519)

      assert check(key, "new.example.com", 22, user_dir: String.to_charlist(dir)) == false
      assert check(key, "new.example.com", 22, known_hosts(dir, ["# empty"])) == false
    end

    test "a host presenting its recorded key is known", %{tmp_dir: dir} do
      key = host_key(:ed25519)
      opts = known_hosts(dir, ["app.example.com,10.0.0.5 #{line(key)} a comment"])

      assert check(key, "app.example.com", 22, opts) == true
      assert KeyProvider.is_host_key(key, [~c"other", {10, 0, 0, 5}], 22, :unused, opts) == true
    end

    test "a host presenting a different key of a recorded type is refused", %{tmp_dir: dir} do
      opts = known_hosts(dir, ["app.example.com #{line(host_key(:ed25519))}"])

      assert check(host_key(:ed25519), "app.example.com", 22, opts) ==
               {:error, {:host_key_changed, "app.example.com"}}
    end

    test "a key of a type not recorded for the host is new, not changed", %{tmp_dir: dir} do
      opts = known_hosts(dir, ["app.example.com #{line(host_key(:ed25519))}"])

      assert check(host_key(:ecdsa), "app.example.com", 22, opts) == false
    end

    test "an RSA key is found under any RSA signature algorithm", %{tmp_dir: dir} do
      key = host_key(:rsa)
      opts = known_hosts(dir, ["app.example.com #{line(key)}"])

      assert KeyProvider.is_host_key(key, [~c"app.example.com"], 22, :"rsa-sha2-512", opts) ==
               true

      assert check(host_key(:rsa), "app.example.com", 22, opts) ==
               {:error, {:host_key_changed, "app.example.com"}}
    end

    test "reads the hashed entries OpenSSH writes with HashKnownHosts", %{tmp_dir: dir} do
      key = host_key(:ed25519)
      opts = known_hosts(dir, ["#{hashed("app.example.com")} #{line(key)}"])

      assert check(key, "app.example.com", 22, opts) == true
      assert check(key, "other.example.com", 22, opts) == false

      assert check(host_key(:ed25519), "app.example.com", 22, opts) ==
               {:error, {:host_key_changed, "app.example.com"}}
    end

    test "a malformed hashed entry names no host", %{tmp_dir: dir} do
      key = host_key(:ed25519)
      opts = known_hosts(dir, ["|1|not-base64|x #{line(key)}", "|1|AAAA|AAAA #{line(key)}"])

      assert check(host_key(:ed25519), "app.example.com", 22, opts) == false
    end

    test "a port other than 22 is recorded as [host]:port", %{tmp_dir: dir} do
      key = host_key(:ed25519)
      opts = known_hosts(dir, ["[app.example.com]:2222 #{line(key)}"])

      assert check(key, "app.example.com", 2222, opts) == true
      assert check(key, "app.example.com", 22, opts) == false

      assert check(host_key(:ed25519), "app.example.com", 2222, opts) ==
               {:error, {:host_key_changed, "app.example.com"}}
    end

    test "wildcards match, and a negated pattern takes a host back out", %{tmp_dir: dir} do
      key = host_key(:ed25519)
      opts = known_hosts(dir, ["*.example.com,!db?.example.com #{line(key)}"])

      assert check(key, "app.example.com", 22, opts) == true
      assert check(key, "db1.example.com", 22, opts) == false
      assert check(key, "example.org", 22, opts) == false
    end

    test "a revoked key is refused even when it is also recorded", %{tmp_dir: dir} do
      key = host_key(:ed25519)

      opts =
        known_hosts(dir, ["app.example.com #{line(key)}", "@revoked app.example.com #{line(key)}"])

      assert check(key, "app.example.com", 22, opts) == {:error, :revoked_key}
    end

    test "a certificate authority line is not a recorded key", %{tmp_dir: dir} do
      key = host_key(:ed25519)
      opts = known_hosts(dir, ["@cert-authority *.example.com #{line(key)}"])

      assert check(key, "app.example.com", 22, opts) == false
      assert check(host_key(:ed25519), "app.example.com", 22, opts) == false
    end

    test "host_key_for names the server a proxied connection reaches", %{tmp_dir: dir} do
      key = host_key(:ed25519)
      private = [host_key_for: {"app.example.com", 2222}]

      opts =
        known_hosts(dir, ["[app.example.com]:2222 #{line(key)}"]) ++ [key_cb_private: private]

      # The proxy dials a local port, which is what :ssh reports.
      assert KeyProvider.is_host_key(key, [~c"127.0.0.1"], 54_321, :unused, opts) == true

      assert quietly(fn ->
               KeyProvider.is_host_key(host_key(:ed25519), [~c"127.0.0.1"], 54_321, :unused, opts)
             end) ==
               {:error, {:host_key_changed, "app.example.com"}}
    end

    test "an accepted key is recorded, under the real host when proxied", %{tmp_dir: dir} do
      key = host_key(:ed25519)
      opts = [user_dir: String.to_charlist(dir)]
      proxied = opts ++ [key_cb_private: [host_key_for: {"app.example.com", 2222}]]

      assert KeyProvider.add_host_key([~c"direct.example.com"], 22, key, opts) == :ok
      assert KeyProvider.add_host_key([~c"127.0.0.1"], 54_321, key, proxied) == :ok

      recorded = File.read!(Path.join(dir, "known_hosts"))
      assert recorded =~ "direct.example.com #{line(key)}"
      assert recorded =~ "[app.example.com]:2222 #{line(key)}"
      refute recorded =~ "127.0.0.1"

      assert check(key, "direct.example.com", 22, opts) == true
      assert check(host_key(:ed25519), "direct.example.com", 22, opts) != true
    end
  end
end
