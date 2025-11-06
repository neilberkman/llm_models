defmodule Mix.Tasks.LlmModels.Pull do
  use Mix.Task

  @shortdoc "Pull latest data from all configured remote sources"

  @moduledoc """
  Pulls latest model metadata from all configured remote sources and caches locally.

  This task iterates through all sources configured in `Config.sources!()` and calls
  their optional `pull/1` callback (if implemented). Sources without a `pull/1` callback
  are skipped. Fetched data is saved to cache directories (typically `priv/llm_models/upstream/`
  or `priv/llm_models/remote/`).

  After pulling, the task generates the `ValidProviders` module from all upstream data
  to prevent atom leaking at runtime.

  To build the final snapshot from fetched data, run `mix llm_models.build`.

  ## Usage

      mix llm_models.pull

  ## Configuration

  Configure sources in your application config:

      config :llm_models,
        sources: [
          {LLMModels.Sources.ModelsDev, %{}},
          {LLMModels.Sources.Local, %{dir: "priv/llm_models"}},
          {LLMModels.Sources.Config, %{overrides: %{...}}}
        ]

  Only sources that implement the optional `pull/1` callback will be pulled.
  Typically only remote sources like `ModelsDev` implement this callback.

  ## Examples

      # Pull from all configured remote sources
      mix llm_models.pull

  ## Output

  The task prints a summary of pull results:

      Pulling from configured sources...

      ✓ LLMModels.Sources.ModelsDev: Updated (709.2 KB)
      ○ LLMModels.Sources.OpenRouter: Not modified
      - LLMModels.Sources.Local: No pull callback (skipped)

      Summary: 1 updated, 1 unchanged, 1 skipped, 0 failed

      Generating valid_providers.ex...
      ✓ Generated with 69 providers

      Run 'mix llm_models.build' to generate snapshot.json
  """

  @default_upstream_dir "priv/llm_models/upstream"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    sources = LLMModels.Config.sources!()

    if sources == [] do
      Mix.shell().info("No sources configured. Add sources to your config:")
      Mix.shell().info("")
      Mix.shell().info("  config :llm_models,")
      Mix.shell().info("    sources: [")
      Mix.shell().info("      {LLMModels.Sources.ModelsDev, %{}}")
      Mix.shell().info("    ]")
      Mix.shell().info("")
      Mix.raise("No sources configured")
    end

    Mix.shell().info("Pulling from configured sources...\n")

    results = pull_all_sources(sources)
    print_summary(results)
    generate_valid_providers()

    Mix.shell().info("\nRun 'mix llm_models.build' to generate snapshot.json")
  end

  # Pull from all sources and return list of {module, result} tuples
  defp pull_all_sources(sources) do
    Enum.map(sources, fn {module, opts} ->
      {module, pull_source(module, opts)}
    end)
  end

  # Pull from a single source
  defp pull_source(module, opts) do
    if has_pull_callback?(module) do
      case module.pull(opts) do
        :noop -> :not_modified
        {:ok, path} -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    else
      :no_callback
    end
  end

  # Check if module implements pull/1 callback
  defp has_pull_callback?(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :pull, 1)
  end

  # Print summary of pull results
  defp print_summary(results) do
    updated = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
    unchanged = Enum.count(results, fn {_, r} -> r == :not_modified end)
    skipped = Enum.count(results, fn {_, r} -> r == :no_callback end)
    failed = Enum.count(results, fn {_, r} -> match?({:error, _}, r) end)

    Enum.each(results, fn {module, result} ->
      print_source_result(module, result)
    end)

    Mix.shell().info("")

    Mix.shell().info(
      "Summary: #{updated} updated, #{unchanged} unchanged, #{skipped} skipped, #{failed} failed"
    )
  end

  # Print result for a single source
  defp print_source_result(module, result) do
    module_name = inspect(module)

    case result do
      {:ok, path} ->
        size = file_size_kb(path)
        Mix.shell().info("✓ #{module_name}: Updated (#{size} KB)")

      :not_modified ->
        Mix.shell().info("○ #{module_name}: Not modified")

      :no_callback ->
        Mix.shell().info("- #{module_name}: No pull callback (skipped)")

      {:error, reason} ->
        Mix.shell().error("✗ #{module_name}: Failed - #{format_error(reason)}")
    end
  end

  # Get file size in KB
  defp file_size_kb(path) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        kb = div(size, 1024)
        Float.round(kb * 1.0, 1)

      _ ->
        "?"
    end
  end

  # Format error reason for display
  defp format_error({:http_status, status}), do: "HTTP #{status}"
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  # Generate ValidProviders module from all upstream data
  defp generate_valid_providers do
    Mix.shell().info("\nGenerating valid_providers.ex...")

    upstream_dir = get_upstream_dir()

    # Find all upstream JSON files (exclude manifest files)
    cache_files =
      case File.ls(upstream_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.reject(&String.ends_with?(&1, ".manifest.json"))

        {:error, :enoent} ->
          []

        {:error, reason} ->
          Mix.raise("Failed to read upstream directory: #{inspect(reason)}")
      end

    if cache_files == [] do
      Mix.shell().info("  ○ No upstream data found - skipping")
    else
      # Collect all provider atoms from all upstream files
      all_providers =
        cache_files
        |> Enum.flat_map(fn file ->
          path = Path.join(upstream_dir, file)
          extract_providers_from_file(path)
        end)
        |> Enum.sort()
        |> Enum.uniq()

      if all_providers == [] do
        Mix.shell().info("  ○ No providers found in upstream data - skipping")
      else
        write_valid_providers_module(all_providers)
        Mix.shell().info("  ✓ Generated with #{length(all_providers)} providers")
      end
    end
  end

  # Extract provider atoms from a single upstream file
  defp extract_providers_from_file(path) do
    case File.read(path) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, data} -> extract_provider_atoms(data)
          {:error, _} -> []
        end

      {:error, _} ->
        []
    end
  end

  # Extract provider atoms from decoded JSON data
  defp extract_provider_atoms(data) when is_map(data) do
    # models.dev format: top-level keys are provider IDs
    # Each provider has "id", "name", "models" fields
    data
    |> Map.keys()
    |> Enum.map(fn key ->
      cond do
        is_atom(key) -> key
        is_binary(key) -> String.to_atom(key)
        true -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_provider_atoms(_), do: []

  # Write the ValidProviders module to disk
  defp write_valid_providers_module(provider_atoms) do
    module_code = """
    defmodule LLMModels.Generated.ValidProviders do
      @moduledoc \"\"\"
      Auto-generated module containing all valid provider atoms.

      This module is generated by `mix llm_models.pull` to prevent atom leaking.
      By pre-generating all provider atoms at build time, we ensure that runtime
      code can only use existing atoms via `String.to_existing_atom/1`.

      DO NOT EDIT THIS FILE MANUALLY - it will be overwritten.
      \"\"\"

      @providers #{inspect(provider_atoms, limit: :infinity)}

      @doc \"\"\"
      Returns the list of all valid provider atoms.
      \"\"\"
      @spec list() :: [atom()]
      def list, do: @providers

      @doc \"\"\"
      Checks if the given atom is a valid provider.
      \"\"\"
      @spec member?(atom()) :: boolean()
      def member?(atom), do: atom in @providers
    end
    """

    module_path = "lib/llm_models/generated/valid_providers.ex"
    File.mkdir_p!(Path.dirname(module_path))
    formatted = Code.format_string!(module_code)
    File.write!(module_path, formatted)
  end

  defp get_upstream_dir do
    Application.get_env(:llm_models, :upstream_cache_dir, @default_upstream_dir)
  end
end
