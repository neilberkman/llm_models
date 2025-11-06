defmodule LLMModels.Config do
  @moduledoc """
  Configuration reading and normalization for LLMModels.

  Reads from Application environment and provides normalized config maps
  and compiled filter patterns.
  """

  require Logger

  @doc """
  Returns the list of sources to load, in precedence order.

  These sources provide raw data that will be merged ON TOP of the packaged
  base snapshot. The packaged snapshot is always loaded first and is not
  included in this sources list.

  ## Configuration

      config :llm_models,
        sources: [
          {LLMModels.Sources.ModelsDev, %{}},
          {LLMModels.Sources.Local, %{dir: "priv/llm_models"}},
          {LLMModels.Sources.Config, %{overrides: %{...}}}
        ]

  ## Default Behavior

  If not configured, returns an empty list `[]`, meaning only the packaged
  snapshot will be used (stable, version-pinned behavior).

  ## Returns

  List of `{module, opts}` tuples in precedence order (first = lowest precedence).
  """
  @spec sources!() :: [{module(), map()}]
  def sources! do
    config = Application.get_all_env(:llm_models)

    case Keyword.get(config, :sources) do
      nil ->
        # Default: Empty list - only use packaged snapshot (stable mode)
        []

      sources when is_list(sources) ->
        sources
    end
  end

  @doc """
  Returns normalized configuration map from Application environment.

  Reads `:llm_models` application config and normalizes with defaults.

  ## Returns

  A map with keys:
  - `:compile_embed` - Whether to compile-time embed snapshot (default: false)
  - `:allow` - Allow patterns (`:all` or `%{provider => [patterns]}`)
  - `:deny` - Deny patterns (`%{provider => [patterns]}`)
  - `:prefer` - List of preferred provider atoms
  """
  @spec get() :: map()
  def get do
    config = Application.get_all_env(:llm_models)

    %{
      compile_embed: Keyword.get(config, :compile_embed, false),
      allow: Keyword.get(config, :allow, :all),
      deny: Keyword.get(config, :deny, %{}),
      prefer: Keyword.get(config, :prefer, [])
    }
  end

  @doc """
  Compiles allow/deny filter patterns to regexes for performance.

  ## Parameters

  - `allow` - `:all` or `%{provider_atom => [pattern_strings]}`
  - `deny` - `%{provider_atom => [pattern_strings]}`

  Patterns support glob syntax with `*` wildcards via `LLMModels.Merge.compile_pattern/1`.

  Deny patterns always win over allow patterns.

  ## Returns

  `%{allow: compiled_patterns, deny: compiled_patterns}`

  Where `compiled_patterns` is either `:all` or `%{provider => [%Regex{}]}`.
  """
  @spec compile_filters(allow :: :all | map(), deny :: map()) :: %{
          allow: :all | map(),
          deny: map()
        }
  def compile_filters(allow, deny) do
    %{
      allow: compile_patterns(allow),
      deny: compile_patterns(deny)
    }
  end

  # Private helpers

  defp compile_patterns(:all), do: :all

  defp compile_patterns(patterns) when is_map(patterns) do
    Map.new(patterns, fn {provider, pattern_list} ->
      compiled = Enum.map(pattern_list, &LLMModels.Merge.compile_pattern/1)
      {provider, compiled}
    end)
  end

  defp compile_patterns(_), do: %{}
end
