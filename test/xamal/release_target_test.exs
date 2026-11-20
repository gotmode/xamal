defmodule Xamal.ReleaseTargetTest do
  # Changes the working directory to a scratch git repository.
  use ExUnit.Case, async: false

  alias Xamal.ReleaseTarget

  describe "same_version?/2" do
    test "matches the same commit abbreviated to different lengths" do
      assert ReleaseTarget.same_version?("9cc073952", "9cc073952")
      assert ReleaseTarget.same_version?("9cc0739", "9cc073952")
      assert ReleaseTarget.same_version?("9cc073952a1b", "9cc073952")
    end

    test "never matches different commits or too short a prefix" do
      refute ReleaseTarget.same_version?("9cc073952", "9cc073953")
      refute ReleaseTarget.same_version?("9cc07", "9cc073952")
      refute ReleaseTarget.same_version?("9cc073952", "9cc073952-local")
    end

    test "matches a non-commit version only exactly" do
      assert ReleaseTarget.same_version?("20260101120000", "20260101120000")
      refute ReleaseTarget.same_version?("release-1", "release-10")
    end
  end

  describe "live?/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "xamal-target-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      previous = File.cwd!()
      File.cd!(dir)

      on_exit(fn ->
        File.cd!(previous)
        File.rm_rf!(dir)
      end)

      git(["init", "-q"])
      older = commit("one")
      newer = commit("two")
      %{older: older, newer: newer}
    end

    test "a commit contained in the live one is live", %{older: older, newer: newer} do
      git(["checkout", "-q", older])
      assert ReleaseTarget.live?(config(short(older)), short(newer))
    end

    test "a commit newer than the live one is not", %{older: older, newer: newer} do
      refute ReleaseTarget.live?(config(short(newer)), short(older))
    end

    test "the commit the queue moved the deploy to counts, not HEAD", %{
      older: older,
      newer: newer
    } do
      git(["checkout", "-q", older])
      config = %{config(short(newer)) | source_commit: newer}

      assert ReleaseTarget.live?(config, short(newer))
      refute ReleaseTarget.live?(config, short(older))
    end

    test "a live release that is no commit here is not live", %{newer: newer} do
      refute ReleaseTarget.live?(config(short(newer)), "#{short(newer)}-local")
      refute ReleaseTarget.live?(config(short(newer)), "abcdef123")
    end
  end

  defp config(version),
    do: %Xamal.Configuration{raw_config: %{"service" => "app"}, version: version}

  defp short(sha), do: String.slice(sha, 0, 9)

  defp commit(message) do
    File.write!("file", message)
    git(["add", "file"])
    git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", message])
    git(["rev-parse", "HEAD"])
  end

  defp git(args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    String.trim(out)
  end
end
