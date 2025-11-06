defmodule LLMModels.Sources.ModelsDev do
  @moduledoc """
  Remote source for models.dev metadata (https://models.dev/api.json).

  - `pull/1` fetches data via Req and caches locally
  - `load/1` reads from cached file (no network call)

  ## Options

  - `:url` - API endpoint (default: "https://models.dev/api.json")
  - `:req_opts` - Additional Req options for testing (e.g., `[plug: test_plug]`)

  ## Configuration

  Cache directory can be configured in application config:

      config :llm_models,
        models_dev_cache_dir: "priv/llm_models/remote"

  Default: `"priv/llm_models/remote"`

  ## Usage

      # Pull remote data and cache
      mix llm_models.pull

      # Load from cache
      {:ok, data} = ModelsDev.load(%{})
  """

  @behaviour LLMModels.Source

  require Logger

  @default_url "https://models.dev/api.json"
  @default_cache_dir "priv/llm_models/remote"

  @impl true
  def pull(opts) do
    url = Map.get(opts, :url, @default_url)
    cache_dir = get_cache_dir()
    cache_path = cache_path(url, cache_dir)
    manifest_path = manifest_path(url, cache_dir)
    req_opts = Map.get(opts, :req_opts, [])

    # Build conditional headers from manifest
    cond_headers = build_cond_headers(manifest_path)
    headers = cond_headers ++ Keyword.get(req_opts, :headers, [])
    req_opts = Keyword.put(req_opts, :headers, headers)

    # Disable automatic JSON decoding for more control
    req_opts = Keyword.put(req_opts, :decode_body, false)

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: 304}} ->
        Logger.info("ModelsDev: not modified (304)")
        :noop

      {:ok, %Req.Response{status: 200, body: body, headers: resp_headers}} ->
        bin =
          cond do
            is_binary(body) and String.starts_with?(body, ["{", "["]) ->
              # Already JSON string
              body

            is_binary(body) ->
              # Try to decode and re-encode for validation
              case Jason.decode(body) do
                {:ok, decoded} -> Jason.encode!(decoded, pretty: true)
                {:error, _} -> body
              end

            is_map(body) or is_list(body) ->
              # Req decoded JSON - re-encode
              Jason.encode!(body, pretty: true)

            true ->
              Jason.encode!(body, pretty: true)
          end

        write_cache(cache_path, manifest_path, bin, url, resp_headers)
        Logger.info("ModelsDev: cached #{byte_size(bin)} bytes to #{cache_path}")
        {:ok, cache_path}

      {:ok, %Req.Response{status: status}} when status >= 400 ->
        {:error, {:http_status, status}}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Unexpected status #{status}")
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def load(opts) do
    url = Map.get(opts, :url, @default_url)
    cache_dir = get_cache_dir()
    cache_path = cache_path(url, cache_dir)

    case File.read(cache_path) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, decoded} -> {:ok, normalize(decoded)}
          {:error, err} -> {:error, {:json_error, err}}
        end

      {:error, :enoent} ->
        {:error, :no_cache}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helpers

  defp get_cache_dir do
    Application.get_env(:llm_models, :models_dev_cache_dir, @default_cache_dir)
  end

  defp cache_path(url, cache_dir) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join(cache_dir, "models-dev-#{hash}.json")
  end

  defp manifest_path(url, cache_dir) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    Path.join(cache_dir, "models-dev-#{hash}.manifest.json")
  end

  defp write_cache(cache_path, manifest_path, content, url, headers) do
    File.mkdir_p!(Path.dirname(cache_path))
    File.write!(cache_path, content)

    manifest = %{
      source_url: url,
      etag: get_header(headers, "etag"),
      last_modified: get_header(headers, "last-modified"),
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      size_bytes: byte_size(content),
      downloaded_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
  end

  defp build_cond_headers(manifest_path) do
    case File.read(manifest_path) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, manifest} ->
            headers = []

            headers =
              case Map.get(manifest, "etag") do
                etag when is_binary(etag) -> [{"if-none-match", etag} | headers]
                _ -> headers
              end

            headers =
              case Map.get(manifest, "last_modified") do
                last_mod when is_binary(last_mod) -> [{"if-modified-since", last_mod} | headers]
                _ -> headers
              end

            headers

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp get_header(headers, name) do
    case Enum.find(headers, fn {k, _} -> String.downcase(k) == name end) do
      {_, [v | _]} when is_list(v) -> v
      {_, v} when is_binary(v) -> v
      {_, v} when is_list(v) -> List.first(v)
      _ -> nil
    end
  end

  defp normalize(content) when is_map(content) do
    # models.dev format: top-level keys are provider IDs,
    # each containing provider metadata + nested "models" map
    # Transform to nested format: %{provider_id => %{...provider, models: [...]}}

    content
    |> Enum.reduce(%{}, fn {provider_id, provider_data}, acc ->
      # Convert provider string keys to atom keys (keep models for now)
      provider_atomized = atomize_keys(provider_data, [:id, :name, :env, :doc])

      # Extract models from nested map and convert to list
      models_map = Map.get(provider_data, "models", %{})

      # Add provider field to each model and atomize keys
      models_list =
        models_map
        |> Map.values()
        |> Enum.map(fn model ->
          model
          |> Map.put("provider", provider_id)
          |> atomize_keys([:id, :provider, :name, :aliases, :deprecated?, :capabilities])
        end)

      # Replace models map with models list and store
      provider_with_list = Map.put(provider_atomized, :models, models_list)
      Map.put(acc, provider_id, provider_with_list)
    end)
  end

  defp normalize(_), do: %{}

  # Convert string keys to atom keys for specific known fields
  defp atomize_keys(map, keys) when is_map(map) do
    Enum.reduce(keys, map, fn key, acc ->
      string_key = to_string(key)

      if Map.has_key?(acc, string_key) do
        acc
        |> Map.put(key, Map.get(acc, string_key))
        |> Map.delete(string_key)
      else
        acc
      end
    end)
  end
end
