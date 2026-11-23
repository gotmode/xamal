# The deploy queue test that runs flock(1) needs it installed (Linux has it,
# macOS does not).
ExUnit.start(exclude: if(System.find_executable("flock"), do: [], else: [:flock]))

# Test connections record host keys here, never in the real ~/.ssh.
ssh_user_dir =
  Path.join(System.tmp_dir!(), "xamal-test-ssh-#{System.unique_integer([:positive])}")

File.mkdir_p!(ssh_user_dir)
Application.put_env(:xamal, :ssh_user_dir, ssh_user_dir)
