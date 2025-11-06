defmodule LLMModels.Source do
  @moduledoc """
  Unified data source interface for LLMModels.

  Sources return only providers and models data. No filtering, no excludes.
  Validation happens later via Engine pipeline.

  ## Type Specifications

  - `provider_id` - Atom or string identifying a provider (e.g., `:openai`, `"anthropic"`)
  - `model_id` - String identifying a model (e.g., `"gpt-4o"`)
  - `provider_map` - Unvalidated provider data map with nested models
  - `model_map` - Unvalidated model data map
  - `data` - Source output with providers map, each containing models list

  ## Contract

  All source implementations must return `{:ok, data}` where data is:

      %{
        "openai" => %{
          id: :openai,
          name: "OpenAI",
          models: [%{id: "gpt-4o", ...}, ...]
        },
        "anthropic" => %{
          id: :anthropic,
          name: "Anthropic",
          models: [%{id: "claude-3-5-sonnet-20241022", ...}, ...]
        }
      }

  Provider keys should be strings, provider data includes an `id` field (atom or string),
  and each provider contains a `models` list.

  Return `{:error, reason}` only if the source cannot produce any data.

  For partial failures (e.g., one file fails in multi-file source), handle
  internally, log warnings, and return available data.

  ## Testability

  Sources should accept optional test hooks via `opts` parameter:
  - `:file_reader` - Function for reading files (default: `File.read!/1`)
  - `:dir_reader` - Function for listing directories (default: `File.ls!/1`)

  This allows tests to inject stubs without filesystem access.
  """

  @type provider_id :: atom() | String.t()
  @type model_id :: String.t()
  @type provider_map :: map()
  @type model_map :: map()
  @type data :: %{required(String.t()) => provider_map}
  @type opts :: map()
  @type pull_result :: :noop | {:ok, String.t()} | {:error, term()}

  @doc """
  Load data from this source.

  For remote sources, this should read from locally cached data (no network calls).
  Run `mix llm_models.pull` to fetch and cache remote data first.

  ## Parameters

  - `opts` - Source-specific options map

  ## Returns

  - `{:ok, data}` - Success with providers/models data
  - `{:error, term}` - Fatal error (source cannot produce any data)
  """
  @callback load(opts) :: {:ok, data} | {:error, term()}

  @doc """
  Pull remote data and cache it locally.

  This callback is optional and only implemented by sources that fetch remote data.
  When implemented, it should:
  - Fetch data from a remote endpoint (e.g., via Req)
  - Cache the data locally in `priv/llm_models/remote/`
  - Write a manifest file with metadata (URL, checksum, timestamp)
  - Support conditional GET using ETag/Last-Modified headers

  ## Parameters

  - `opts` - Source-specific options map (may include `:url`, `:cache_id`, etc.)

  ## Returns

  - `:noop` - Data not modified (HTTP 304)
  - `{:ok, cache_path}` - Successfully cached to the given path
  - `{:error, term}` - Failed to fetch or cache
  """
  @callback pull(opts) :: pull_result

  @optional_callbacks pull: 1
end
