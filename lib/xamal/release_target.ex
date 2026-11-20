defmodule Xamal.ReleaseTarget do
  @moduledoc """
  Decides what a deploy releases once it holds the deploy queue.

  Two things can change it. A deploy that waited behind another one moves to
  the newest commit of `deploy_queue.follow` when that commit contains its
  own, so a burst of merges ships in one deploy instead of one per merge. And
  a deploy whose commit is already live, or already contained in what is
  live, releases nothing.
  """

  import Xamal.Output
  import Xamal.Remote

  alias Xamal.Commands.App
  alias Xamal.Configuration
  alias Xamal.Configuration.{Builder, DeployQueue}
  alias Xamal.Context

  # A commit that changes any of these needs a deploy run from a checkout of
  # it, since the config, hooks and secrets come from the working tree.
  @deploy_config_paths ["config/xamal.exs", "config/xamal", ".xamal"]

  @spec resolve(Context.t(), keyword(), boolean()) ::
          {:deploy, Context.t()} | {:already_live, String.t()}
  def resolve(%Context{} = context, opts, waited) do
    queue = context.config.deploy_queue || %DeployQueue{}
    # Fetched even when the deploy will not follow it, so a commit that is
    # already contained in what is live is recognised as such and never
    # deployed over it.
    if is_binary(queue.follow), do: fetch(queue.follow)

    context = if follow?(context.config, opts, waited), do: follow(context), else: context

    case live_version(context) do
      nil ->
        {:deploy, context}

      live ->
        if live?(context.config, live), do: {:already_live, live}, else: {:deploy, context}
    end
  end

  defp follow?(config, opts, waited) do
    queue = config.deploy_queue || %DeployQueue{}

    waited and is_binary(queue.follow) and Builder.remote?(config.builder) and
      not Keyword.get(opts, :skip_build, false) and Keyword.get(opts, :version) == nil and
      System.get_env("VERSION") in [nil, ""]
  end

  defp follow(context) do
    config = context.config
    ref = config.deploy_queue.follow

    with {:ok, head} <- git(["rev-parse", "HEAD"]),
         {:ok, target} <- git(["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]),
         :newer <- compare(head, target, ref),
         :ok <- same_deploy_config(head, target, ref),
         {:ok, version} <- git(["rev-parse", "--short=#{short_length(config.version)}", target]) do
      {:ok, count} = git(["rev-list", "--count", "#{head}..#{target}"])

      say(
        "#{ref} moved on while this deploy waited. Deploying #{version}, " <>
          "which adds #{count} newer commit(s) to #{config.version}",
        :magenta
      )

      Context.put_config(context, %{config | version: version, source_commit: target})
    else
      _ -> context
    end
  end

  defp fetch(ref) do
    case String.split(ref, "/", parts: 2) do
      [remote, branch] ->
        if git(["fetch", "--quiet", remote, branch]) == :error do
          say("Could not fetch #{ref}, using the copy already here", :yellow)
        end

      _ ->
        :ok
    end
  end

  defp compare(same, same, _ref), do: :same

  defp compare(head, target, ref) do
    if ancestor?(head, target) do
      :newer
    else
      say("This commit is not on #{ref}, so the deploy stays on it", :yellow)
      :diverged
    end
  end

  defp same_deploy_config(head, target, ref) do
    case System.cmd("git", ["diff", "--quiet", head, target, "--" | @deploy_config_paths],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      _ ->
        say(
          "#{ref} changes the deploy config since this commit, so this deploy stays on it. " <>
            "Deploy #{ref} from a checkout of it to ship the rest.",
          :yellow
        )

        :changed
    end
  end

  defp short_length(version) do
    if version =~ ~r/^[0-9a-f]{7,40}$/, do: String.length(version), else: 9
  end

  defp live_version(context) do
    case on_primary(App.current_version(context.config), context) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> nil
          live -> live
        end

      {:error, _} ->
        nil
    end
  end

  @doc """
  Whether `live` already carries the version being deployed, as the same
  commit or one that contains it.
  """
  @spec live?(Configuration.t(), String.t()) :: boolean()
  def live?(config, live) do
    same_version?(config.version, live) or contained?(config, live)
  end

  @doc false
  def same_version?(version, live) do
    short = min(String.length(version), String.length(live))

    version == live or
      (short >= 7 and hex?(version) and hex?(live) and
         String.slice(version, 0, short) == String.slice(live, 0, short))
  end

  defp contained?(config, live) do
    commit = config.source_commit || "HEAD"

    with true <- hex?(live),
         {:ok, sha} <- git(["rev-parse", "--verify", "--quiet", commit <> "^{commit}"]),
         true <- String.starts_with?(sha, config.version),
         {:ok, live_sha} <- git(["rev-parse", "--verify", "--quiet", live <> "^{commit}"]) do
      ancestor?(sha, live_sha)
    else
      _ -> false
    end
  end

  defp hex?(value), do: value =~ ~r/^[0-9a-f]+$/

  defp ancestor?(commit, of) do
    match?(
      {_, 0},
      System.cmd("git", ["merge-base", "--is-ancestor", commit, of], stderr_to_stdout: true)
    )
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> :error
    end
  end
end
