defmodule Xamal.SSH.KeyProvider do
  @moduledoc """
  Custom SSH key callback that serves a single configured private key.

  Takes `key_file: path` (the key from `ssh.keys`, read on use) or
  `key_data: fun` (a zero-arity function returning the PEM, for `ssh.key_data`
  fetched from e.g. 1Password via `op read`). The key is never passed by value
  so it cannot appear in exit reasons or crash reports that print the options.

  ## Host keys

  A server's host key is checked against `known_hosts` in the user's SSH
  directory (`~/.ssh`, or the `:user_dir` connect option), the same file
  OpenSSH and the `scp` transfers use:

  - a host seen for the first time is accepted and recorded,
  - a host whose recorded key matches is accepted,
  - a host that presents a different key of a type already recorded for it is
    refused, as is a key the file marks `@revoked`.

  This is `StrictHostKeyChecking=accept-new`. Erlang's own lookup answers
  "not known" both for a new host and for a changed key, and cannot read the
  hashed entries OpenSSH writes by default on Debian and Ubuntu, so the lookup
  is done here.

  `host_key_for: {host, port}` in the private options names the server a
  proxied connection really reaches. `Xamal.SSH.Proxy` dials a local port, and
  without it the key would be looked up under `127.0.0.1`.
  """

  @behaviour :ssh_client_key_api

  @impl true
  def is_host_key(key, hosts, port, _algorithm, opts) do
    {hosts, port} = target(hosts, port, opts)
    {type, blob} = encoded(key)

    case File.read(known_hosts_path(opts)) do
      {:ok, contents} ->
        contents
        |> entries(names(hosts, port))
        |> verdict(type, blob, hosts)
        |> explain(hosts, port)

      {:error, :enoent} ->
        false

      {:error, reason} ->
        {:error, {:known_hosts, reason}}
    end
  end

  @impl true
  def add_host_key(hosts, port, key, opts) do
    {hosts, port} = target(hosts, port, opts)
    :ssh_file.add_host_key(hosts, port, key, Keyword.put(opts, :user_dir, user_dir(opts)))
  end

  # :ssh reports any refusal only as "Key exchange failed", so say why here.
  defp explain({:error, reason} = refused, hosts, port) do
    name = hosts |> names(port) |> hd()

    why =
      case reason do
        :revoked_key -> "is marked @revoked in known_hosts"
        _changed -> "does not match the one recorded in known_hosts"
      end

    IO.puts(:stderr, """
    The SSH host key that #{name} presented #{why}, so Xamal did not connect.
    Someone may be intercepting the connection. If the server's key really
    changed, remove the old one with `ssh-keygen -R '#{name}'` and try again.\
    """)

    refused
  end

  defp explain(verdict, _hosts, _port), do: verdict

  defp target(hosts, port, opts) do
    case (opts[:key_cb_private] || [])[:host_key_for] do
      {host, target_port} -> {[to_charlist(host)], target_port}
      nil -> {List.wrap(hosts), port}
    end
  end

  defp known_hosts_path(opts), do: Path.join(to_string(user_dir(opts)), "known_hosts")

  # The tests point :ssh_user_dir at a scratch directory so a test connection
  # never writes to the real ~/.ssh/known_hosts.
  defp user_dir(opts) do
    dir =
      opts[:user_dir] || Application.get_env(:xamal, :ssh_user_dir) ||
        Path.join(System.user_home!(), ".ssh")

    to_charlist(dir)
  end

  # The key the way known_hosts writes it, {"ssh-ed25519", "AAAA..."}.
  defp encoded(key) do
    [type, blob | _comment] =
      [{key, []}] |> :ssh_file.encode(:openssh_key) |> IO.iodata_to_binary() |> String.split()

    {type, blob}
  end

  # known_hosts names a host on port 22 bare and any other port as [host]:port.
  defp names(hosts, port) do
    hosts
    |> Enum.map(&host_name/1)
    |> Enum.uniq()
    |> Enum.map(fn name -> if port == 22, do: name, else: "[#{name}]:#{port}" end)
  end

  defp host_name(host) when is_tuple(host), do: host |> :inet.ntoa() |> to_string()
  defp host_name(host), do: to_string(host)

  # Every line that names one of the hosts, as {marker, type, blob}.
  defp entries(contents, names) do
    contents
    |> String.split(["\n", "\r\n"], trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        ["#" <> _comment | _rest] -> []
        ["@" <> marker, patterns, type, blob | _comment] -> [{marker, patterns, type, blob}]
        [patterns, type, blob | _comment] -> [{nil, patterns, type, blob}]
        _malformed -> []
      end
    end)
    |> Enum.filter(fn {_marker, patterns, _type, _blob} -> names_match?(names, patterns) end)
    |> Enum.map(fn {marker, _patterns, type, blob} -> {marker, type, blob} end)
  end

  # A certificate authority line vouches for certificates, which this client
  # does not present or check, so it never counts as a recorded key.
  defp verdict(entries, type, blob, hosts) do
    recorded = for {nil, ^type, recorded_blob} <- entries, do: recorded_blob

    cond do
      {"revoked", type, blob} in entries -> {:error, :revoked_key}
      blob in recorded -> true
      recorded == [] -> false
      true -> {:error, {:host_key_changed, hosts |> hd() |> host_name()}}
    end
  end

  # A line names a host when one of its patterns matches and none of its
  # negated (!) patterns does.
  defp names_match?(names, patterns) do
    {negated, positive} =
      patterns |> String.split(",", trim: true) |> Enum.split_with(&String.starts_with?(&1, "!"))

    Enum.any?(names, fn name ->
      Enum.any?(positive, &pattern_match?(name, &1)) and
        not Enum.any?(negated, &pattern_match?(name, String.trim_leading(&1, "!")))
    end)
  end

  # OpenSSH's HashKnownHosts form, |1|salt|HMAC-SHA1(salt, name), both base64.
  defp pattern_match?(name, "|1|" <> hashed) do
    with [salt64, hash64] <- String.split(hashed, "|"),
         {:ok, salt} <- Base.decode64(salt64),
         {:ok, hash} <- Base.decode64(hash64),
         expected = :crypto.mac(:hmac, :sha, salt, name),
         true <- byte_size(hash) == byte_size(expected) do
      :crypto.hash_equals(expected, hash)
    else
      _malformed -> false
    end
  end

  defp pattern_match?(name, pattern) do
    source =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")

    Regex.match?(Regex.compile!("\\A#{source}\\z"), name)
  end

  @impl true
  def user_key(algorithm, opts) do
    private = opts[:key_cb_private] || []

    cond do
      socket = private[:agent] -> :ssh_agent.user_key(algorithm, agent_opts(opts, socket))
      private[:key_file] || private[:key_data] -> configured_key(algorithm, private)
      true -> :ssh_file.user_key(algorithm, opts)
    end
  end

  # Only reached for the agent, whose user_key answers with the public key
  # blob and leaves the signature to the agent.
  @impl true
  def sign(blob, data, opts) do
    :ssh_agent.sign(blob, data, agent_opts(opts, (opts[:key_cb_private] || [])[:agent]))
  end

  defp agent_opts(opts, socket), do: Keyword.put(opts, :key_cb_private, socket_path: socket)

  defp configured_key(algorithm, private) do
    with {:ok, key_data} <- read_key(private) do
      case decode_pem_key(key_data, algorithm) do
        {:ok, key} -> {:ok, key}
        :none -> {:error, :no_matching_key}
      end
    end
  end

  defp read_key(private) do
    cond do
      path = private[:key_file] -> File.read(path)
      is_function(private[:key_data], 0) -> {:ok, private[:key_data].()}
      true -> {:ok, private[:key_data]}
    end
  end

  defp decode_pem_key(pem_data, algorithm) when is_binary(pem_data) do
    pem_data
    |> decode_keys()
    |> Enum.find_value(:none, fn key ->
      if key_matches_algorithm?(key, algorithm), do: {:ok, key}
    end)
  end

  defp decode_pem_key(_, _), do: :none

  # "-----BEGIN OPENSSH PRIVATE KEY-----" is what ssh-keygen writes by default;
  # :public_key only reads the older PEM formats (RSA/EC/PKCS#8).
  defp decode_keys(data) do
    case :ssh_file.decode(data, :openssh_key_v1) do
      entries when is_list(entries) and entries != [] ->
        Enum.map(entries, fn {key, _attrs} -> key end)

      _ ->
        data
        |> :public_key.pem_decode()
        |> Enum.flat_map(&decode_pem_entry/1)
    end
  end

  defp decode_pem_entry(entry) do
    [:public_key.pem_entry_decode(entry)]
  rescue
    _ -> []
  end

  # PKCS#8 Ed25519 (OID 1.3.101.112)
  defp key_matches_algorithm?(
         {:ECPrivateKey, _, _, {:namedCurve, {1, 3, 101, 112}}, _, _},
         :"ssh-ed25519"
       ),
       do: true

  # ECDSA keys (5-element tuple)
  defp key_matches_algorithm?({:ECPrivateKey, _, _, _, _}, alg),
    do: String.starts_with?(Atom.to_string(alg), "ecdsa-sha2-")

  # ECDSA keys (6-element tuple, non-Ed25519 curves)
  defp key_matches_algorithm?({:ECPrivateKey, _, _, curve, _, _}, alg)
       when curve != {:namedCurve, {1, 3, 101, 112}},
       do: String.starts_with?(Atom.to_string(alg), "ecdsa-sha2-")

  defp key_matches_algorithm?({:RSAPrivateKey, _, _, _, _, _, _, _, _, _, _}, alg)
       when alg in [:"ssh-rsa", :"rsa-sha2-256", :"rsa-sha2-512"],
       do: true

  defp key_matches_algorithm?({:ed_pri, :ed25519, _, _}, :"ssh-ed25519"), do: true

  defp key_matches_algorithm?(_, _), do: false
end
