defmodule LLMModels.Engine do
  @moduledoc """
  Pure ETL pipeline for BUILD-TIME LLM model catalog generation.

  Engine is a pure function: sources in, snapshot out. It processes ONLY
  the sources explicitly passed via options or configured sources - no
  packaged base layer, no runtime overrides.

  This module is designed for BUILD-TIME use (e.g., mix tasks) to generate
  snapshots from remote/local sources that will be packaged into the library.

  ## Pipeline Stages

  1. **Ingest** - Load data from configured sources
  2. **Normalize** - Apply normalization to providers and models per layer
  3. **Validate** - Validate schemas and log dropped records per layer
  4. **Merge** - Combine layers with precedence rules (last wins)
  5. **Finalize** - Filter, enrich, and index the final catalog
  6. **Ensure viable** - Verify catalog has content (warns if empty)

  ## Architecture

  Sources are processed in order with last-wins precedence:
  1. First source (lowest precedence)
  2. Second source
  3. ... (higher precedence)
  4. Last source (highest precedence)

  The engine coordinates data ingestion, normalization, validation, merging,
  and finalization to produce a comprehensive model snapshot.
  """

  require Logger

  alias LLMModels.{Config, Enrich, Merge, Normalize, Validate}

  @doc """
  Runs the complete ETL pipeline to generate a model catalog snapshot.

  Pure function that processes sources into a snapshot. BUILD-TIME only.

  ## Options

  - `:sources` - List of `{module, opts}` source tuples (optional, defaults to Config.sources!())
  - `:allow` - Allow patterns (optional, defaults to Config allow)
  - `:deny` - Deny patterns (optional, defaults to Config deny)
  - `:prefer` - List of preferred provider atoms (optional, defaults to Config prefer)

  ## Returns

  - `{:ok, snapshot_map}` - Success with indexed snapshot
  - `{:ok, snapshot_map}` - Empty catalog (warns but succeeds if no sources)
  - `{:error, term}` - Other error

  ## Snapshot Structure

  ```elixir
  %{
    providers_by_id: %{atom => Provider.t()},
    models_by_key: %{{atom, String.t()} => Model.t()},
    aliases_by_key: %{{atom, String.t()} => String.t()},
    providers: [Provider.t()],
    models: %{atom => [Model.t()]},
    filters: %{allow: compiled, deny: compiled},
    prefer: [atom],
    meta: %{epoch: nil, generated_at: String.t()}
  }
  ```
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, layers_data} <- ingest(opts),
         {:ok, normalized} <- normalize_layers(layers_data),
         {:ok, validated} <- validate_layers(normalized),
         {:ok, merged} <- merge_layers(validated),
         {:ok, snapshot} <- finalize(merged),
         :ok <- ensure_viable(snapshot) do
      {:ok, snapshot}
    end
  end

  # Stage 1: Ingest - load data from configured sources only
  defp ingest(opts) do
    config = Config.get()

    # Get sources list (from opts or config)
    sources_list =
      case Keyword.get(opts, :sources) do
        nil -> Config.sources!()
        sources when is_list(sources) -> sources
      end

    # Warn if no sources provided
    if sources_list == [] do
      Logger.warning("No sources configured - catalog will be empty")
    end

    # Load data from each source
    source_layers =
      Enum.map(sources_list, fn {module, source_opts} ->
        case module.load(source_opts) do
          {:ok, data} ->
            {providers, models} = flatten_nested_data(data)

            %{
              name: module,
              providers: providers,
              models: models
            }

          {:error, reason} ->
            Logger.warning("Source #{inspect(module)} failed to load: #{inspect(reason)}")

            %{
              name: module,
              providers: [],
              models: []
            }
        end
      end)

    # Get filters and prefer from opts or config
    layers_data = %{
      layers: source_layers,
      filters: %{
        allow: Keyword.get(opts, :allow, config.allow),
        deny: Keyword.get(opts, :deny, config.deny)
      },
      prefer: Keyword.get(opts, :prefer, config.prefer)
    }

    {:ok, layers_data}
  end

  # Stage 2: Normalize - apply to each layer
  defp normalize_layers(layers_data) do
    normalized_layers =
      Enum.map(layers_data.layers, fn layer ->
        %{
          name: layer.name,
          providers: Normalize.normalize_providers(layer.providers),
          models: Normalize.normalize_models(layer.models)
        }
      end)

    {:ok,
     %{
       layers: normalized_layers,
       filters: layers_data.filters,
       prefer: layers_data.prefer
     }}
  end

  # Stage 3: Validate - apply to each layer and log results
  defp validate_layers(normalized) do
    validated_layers =
      Enum.map(normalized.layers, fn layer ->
        {:ok, providers, providers_dropped} = Validate.validate_providers(layer.providers)
        {:ok, models, models_dropped} = Validate.validate_models(layer.models)

        if providers_dropped > 0 do
          Logger.warning(
            "Dropped #{providers_dropped} invalid provider(s) from #{inspect(layer.name)}"
          )
        end

        if models_dropped > 0 do
          Logger.warning("Dropped #{models_dropped} invalid model(s) from #{inspect(layer.name)}")
        end

        %{
          name: layer.name,
          providers: providers,
          models: models
        }
      end)

    {:ok,
     %{
       layers: validated_layers,
       filters: normalized.filters,
       prefer: normalized.prefer
     }}
  end

  # Stage 4: Merge - combine all layers with precedence (last wins)
  defp merge_layers(validated) do
    # Reduce layers left-to-right (first = lowest precedence, last = highest)
    {providers, models} =
      Enum.reduce(validated.layers, {[], []}, fn layer, {acc_providers, acc_models} ->
        {
          Merge.merge_providers(acc_providers, layer.providers),
          merge_models_with_list_rules(acc_models, layer.models)
        }
      end)

    merged = %{
      providers: providers,
      models: models,
      filters: validated.filters,
      prefer: validated.prefer
    }

    {:ok, merged}
  end

  # Stage 5: Finalize (Filter → Enrich → Index)
  defp finalize(merged) do
    # Step 1: Filter - compile and apply allow/deny patterns
    compiled_filters = Config.compile_filters(merged.filters.allow, merged.filters.deny)
    filtered_models = apply_filters(merged.models, compiled_filters)

    # Step 2: Enrich - derive family, ensure provider_model_id, apply defaults
    enriched_models = Enrich.enrich_models(filtered_models)

    # Step 3: Index - build lookup indexes for O(1) access
    indexes = build_indexes(merged.providers, enriched_models)

    # Step 4: Build snapshot structure
    snapshot = %{
      providers_by_id: indexes.providers_by_id,
      models_by_key: indexes.models_by_key,
      aliases_by_key: indexes.aliases_by_key,
      providers: merged.providers,
      models: indexes.models_by_provider,
      filters: compiled_filters,
      prefer: merged.prefer,
      meta: %{
        epoch: nil,
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    {:ok, snapshot}
  end

  # Stage 6: Ensure viable - warn on empty catalog but don't error
  defp ensure_viable(snapshot) do
    providers = snapshot.providers
    models = Map.values(snapshot.models) |> List.flatten()

    if providers == [] or models == [] do
      Logger.warning("Empty catalog generated - no providers or models found")
    end

    :ok
  end

  @doc """
  Builds lookup indexes for providers, models, and aliases.

  ## Returns

  A map with:
  - `:providers_by_id` - %{atom => Provider.t()}
  - `:models_by_key` - %{{atom, String.t()} => Model.t()}
  - `:models_by_provider` - %{atom => [Model.t()]}
  - `:aliases_by_key` - %{{atom, String.t()} => String.t()}
  """
  @spec build_indexes([map()], [map()]) :: map()
  def build_indexes(providers, models) do
    providers_by_id = Map.new(providers, fn p -> {p.id, p} end)

    models_by_key = Map.new(models, fn m -> {{m.provider, m.id}, m} end)

    models_by_provider =
      Enum.group_by(models, & &1.provider)
      |> Map.new(fn {provider, models_list} -> {provider, models_list} end)

    aliases_by_key = build_aliases_index(models)

    %{
      providers_by_id: providers_by_id,
      models_by_key: models_by_key,
      models_by_provider: models_by_provider,
      aliases_by_key: aliases_by_key
    }
  end

  @doc """
  Applies allow/deny filters to models.

  Deny patterns always win over allow patterns.

  ## Parameters

  - `models` - List of model maps
  - `filters` - %{allow: compiled_patterns, deny: compiled_patterns}

  ## Returns

  Filtered list of models
  """
  @spec apply_filters([map()], map()) :: [map()]
  def apply_filters(models, %{allow: allow, deny: deny}) do
    models
    |> Enum.filter(fn model ->
      provider = model.provider
      model_id = model.id

      # Deny wins - check first
      deny_patterns = Map.get(deny, provider, [])

      if matches_patterns?(model_id, deny_patterns) do
        false
      else
        # Then check allow
        case allow do
          :all ->
            true

          allow_map when is_map(allow_map) ->
            allow_patterns = Map.get(allow_map, provider, [])

            if map_size(allow_map) > 0 and allow_patterns == [] do
              false
            else
              allow_patterns == [] or matches_patterns?(model_id, allow_patterns)
            end
        end
      end
    end)
  end

  @doc """
  Builds an alias index mapping {provider, alias} to canonical model ID.

  ## Parameters

  - `models` - List of model maps

  ## Returns

  %{{provider_atom, alias_string} => canonical_id_string}
  """
  @spec build_aliases_index([map()]) :: %{{atom(), String.t()} => String.t()}
  def build_aliases_index(models) do
    models
    |> Enum.flat_map(fn model ->
      provider = model.provider
      canonical_id = model.id
      aliases = Map.get(model, :aliases, [])

      Enum.map(aliases, fn alias_name ->
        {{provider, alias_name}, canonical_id}
      end)
    end)
    |> Map.new()
  end

  # Private helpers

  # Merge models with special list handling rules
  # Union for known list fields (aliases), replace for others
  defp merge_models_with_list_rules(base_models, override_models) do
    base_map = Map.new(base_models, fn m -> {{Map.get(m, :provider), Map.get(m, :id)}, m} end)

    override_map =
      Map.new(override_models, fn m -> {{Map.get(m, :provider), Map.get(m, :id)}, m} end)

    Map.merge(base_map, override_map, fn _identity, base_model, override_model ->
      deep_merge_with_list_rules(base_model, override_model)
    end)
    |> Map.values()
  end

  # Deep merge with special list handling
  defp deep_merge_with_list_rules(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn key, left_val, right_val ->
      cond do
        is_map(left_val) and is_map(right_val) ->
          deep_merge_with_list_rules(left_val, right_val)

        is_list(left_val) and is_list(right_val) ->
          # Union-dedupe for aliases, replace for others
          if key in [:aliases] do
            (right_val ++ left_val) |> Enum.uniq()
          else
            right_val
          end

        true ->
          # Scalar: last wins (right has higher precedence)
          right_val
      end
    end)
  end

  defp matches_patterns?(_model_id, []), do: false

  defp matches_patterns?(model_id, patterns) when is_binary(model_id) do
    Enum.any?(patterns, fn
      %Regex{} = pattern -> Regex.match?(pattern, model_id)
      pattern when is_binary(pattern) -> model_id == pattern
    end)
  end

  defp flatten_nested_data(data) when is_map(data) do
    Enum.reduce(data, {[], []}, fn {_provider_id, provider_data}, {provs_acc, mods_acc} ->
      models = Map.get(provider_data, :models, Map.get(provider_data, "models", []))
      provider = Map.delete(Map.delete(provider_data, :models), "models")

      {[provider | provs_acc], models ++ mods_acc}
    end)
  end
end
