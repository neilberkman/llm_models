defmodule Mix.Tasks.LlmModels.Build do
  use Mix.Task

  @shortdoc "Build snapshot.json from sources using the ETL pipeline"

  @moduledoc """
  Builds snapshot.json from configured sources using the Engine ETL pipeline.

  Runs the complete ETL pipeline (Ingest → Normalize → Validate → Merge →
  Enrich → Filter → Index) on configured sources to generate a fresh
  snapshot.json file.

  ## Usage

      mix llm_models.build

  ## Configuration

  Configure sources in your application config:

      config :llm_models,
        sources: [
          {LLMModels.Sources.Packaged, %{}},
          {LLMModels.Sources.ModelsDev, %{url: "https://models.dev/api.json"}},
          {LLMModels.Sources.JSONFile, %{paths: ["priv/custom.json"]}}
        ],
        allow: :all,
        deny: %{},
        prefer: [:openai, :anthropic]
  """

  @snapshot_path "priv/llm_models/snapshot.json"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info("Building snapshot from configured sources...\n")

    {:ok, snapshot} = build_snapshot()
    save_snapshot(snapshot)
    print_summary(snapshot)
  end

  defp build_snapshot do
    config = LLMModels.Config.get()
    sources = LLMModels.Config.sources!()

    if sources == [] do
      Mix.shell().info("Warning: No sources configured - snapshot will be empty\n")
    end

    LLMModels.Engine.run(
      sources: sources,
      allow: config.allow,
      deny: config.deny,
      prefer: config.prefer
    )
  end

  defp save_snapshot(snapshot) do
    @snapshot_path
    |> Path.dirname()
    |> File.mkdir_p!()

    output_data = %{
      "providers" => Enum.map(snapshot.providers, &map_with_string_keys/1),
      "models" =>
        Map.values(snapshot.models) |> List.flatten() |> Enum.map(&map_with_string_keys/1)
    }

    json = Jason.encode!(output_data, pretty: true)
    File.write!(@snapshot_path, json)

    Mix.shell().info("✓ Snapshot written to #{@snapshot_path}")
  end

  defp print_summary(snapshot) do
    provider_count = length(snapshot.providers)
    model_count = Map.values(snapshot.models) |> Enum.map(&length/1) |> Enum.sum()

    Mix.shell().info("")
    Mix.shell().info("Summary:")
    Mix.shell().info("  Providers: #{provider_count}")
    Mix.shell().info("  Models: #{model_count}")
  end

  defp map_with_string_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), map_with_string_keys(v)}
      {k, v} -> {k, map_with_string_keys(v)}
    end)
  end

  defp map_with_string_keys(list) when is_list(list) do
    Enum.map(list, &map_with_string_keys/1)
  end

  defp map_with_string_keys(value), do: value
end
