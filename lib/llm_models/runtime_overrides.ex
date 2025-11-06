defmodule LLMModels.RuntimeOverrides do
  @moduledoc """
  Provides lightweight runtime filtering and preference updates without running the full Engine.

  This module allows you to apply runtime overrides to an existing snapshot:
  - Recompile and reapply filters (allow/deny patterns)
  - Update provider preferences

  Unlike the full Engine pipeline, this does not:
  - Add new providers or models
  - Run normalization or validation
  - Modify provider or model data

  ## Example

      snapshot = LLMModels.Store.snapshot()
      overrides = %{
        filters: %{
          allow: %{openai: ["gpt-4"]},
          deny: %{}
        },
        prefer: [:openai, :anthropic]
      }

      {:ok, updated_snapshot} = LLMModels.RuntimeOverrides.apply(snapshot, overrides)
  """

  require Logger

  alias LLMModels.{Config, Engine}
  alias LLMModels.Generated.ValidProviders

  @doc """
  Applies runtime overrides to an existing snapshot.

  ## Parameters

  - `snapshot` - The current snapshot map
  - `overrides` - Map with optional `:filters` and `:prefer` keys

  ## Override Options

  - `:filters` - %{allow: patterns, deny: patterns} to recompile and reapply
  - `:prefer` - List of provider atoms to update preference order

  ## Returns

  - `{:ok, updated_snapshot}` - Success with updated snapshot
  - `{:error, reason}` - Validation or processing error
  """
  @spec apply(map(), map() | nil) :: {:ok, map()} | {:error, term()}
  def apply(snapshot, overrides) when is_map(snapshot) do
    case validate_and_prepare_overrides(overrides) do
      {:ok, prepared} ->
        apply_overrides(snapshot, prepared)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Validate and prepare overrides
  defp validate_and_prepare_overrides(nil), do: {:ok, %{}}
  defp validate_and_prepare_overrides(overrides) when overrides == %{}, do: {:ok, %{}}

  defp validate_and_prepare_overrides(overrides) when is_map(overrides) do
    with :ok <- validate_filters(overrides[:filters]),
         :ok <- validate_prefer(overrides[:prefer]) do
      {:ok, overrides}
    end
  end

  # Validate filters structure
  defp validate_filters(nil), do: :ok
  defp validate_filters(%{} = filters) when map_size(filters) == 0, do: :ok

  defp validate_filters(%{allow: allow, deny: deny}) do
    cond do
      not is_map(allow) and allow != :all ->
        {:error, "filters.allow must be a map or :all"}

      not is_map(deny) ->
        {:error, "filters.deny must be a map"}

      true ->
        :ok
    end
  end

  defp validate_filters(_), do: {:error, "filters must be %{allow: ..., deny: ...}"}

  # Validate prefer list
  defp validate_prefer(nil), do: :ok
  defp validate_prefer([]), do: :ok

  defp validate_prefer(prefer) when is_list(prefer) do
    invalid =
      Enum.reject(prefer, fn
        atom when is_atom(atom) -> ValidProviders.member?(atom)
        _ -> false
      end)

    if invalid == [] do
      :ok
    else
      {:error, "prefer contains invalid provider atoms: #{inspect(invalid)}"}
    end
  end

  defp validate_prefer(_), do: {:error, "prefer must be a list of atoms"}

  # Apply validated overrides to snapshot
  defp apply_overrides(snapshot, overrides) do
    snapshot
    |> maybe_update_filters(overrides[:filters])
    |> maybe_update_prefer(overrides[:prefer])
    |> wrap_ok()
  end

  # Update filters and reapply to models
  defp maybe_update_filters(snapshot, nil), do: snapshot
  defp maybe_update_filters(snapshot, filters) when map_size(filters) == 0, do: snapshot

  defp maybe_update_filters(snapshot, filters) do
    # Compile new filters
    compiled_filters =
      Config.compile_filters(
        Map.get(filters, :allow, :all),
        Map.get(filters, :deny, %{})
      )

    # Extract all models from the snapshot
    all_models = Map.values(snapshot.models) |> List.flatten()

    # Reapply filters
    filtered_models = Engine.apply_filters(all_models, compiled_filters)

    # Rebuild indexes with filtered models
    indexes = Engine.build_indexes(snapshot.providers, filtered_models)

    # Update snapshot
    %{
      snapshot
      | filters: compiled_filters,
        models_by_key: indexes.models_by_key,
        models: indexes.models_by_provider,
        aliases_by_key: indexes.aliases_by_key
    }
  end

  # Update prefer list
  defp maybe_update_prefer(snapshot, nil), do: snapshot
  defp maybe_update_prefer(snapshot, []), do: snapshot

  defp maybe_update_prefer(snapshot, prefer) when is_list(prefer) do
    %{snapshot | prefer: prefer}
  end

  # Wrap result in :ok tuple
  defp wrap_ok(snapshot), do: {:ok, snapshot}
end
