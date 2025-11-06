# LLM Models

[![Hex.pm](https://img.shields.io/hexpm/v/llm_models.svg)](https://hex.pm/packages/llm_models)
[![License](https://img.shields.io/hexpm/l/llm_models.svg)](https://github.com/agentjido/llm_models/blob/main/LICENSE)

LLM model metadata catalog with fast, capability-aware lookups. Use simple `"provider:model"` specs, get validated Provider/Model structs, and select models by capabilities. Ships with a packaged snapshot; no network required by default.

- **Primary interface**: `model_spec` — a string like `"openai:gpt-4o-mini"`
- **Fast O(1) reads** via `:persistent_term`
- **Minimal dependencies** 

## Installation

Model metadata is refreshed regularly, so versions follow a date-based format (`YYYY.MM.DD`):

```elixir
def deps do
  [
    {:llm_models, "~> 2025.11.0"}
  ]
end
```

## model_spec (the main interface)

A `model_spec` is `"provider:model"` (e.g., `"openai:gpt-4o-mini"`).

Use it to fetch model structs or resolve identifiers. Tuples `{:provider_atom, "id"}` also work, but prefer the string spec.

```elixir
{:ok, model} = LLMModels.model("openai:gpt-4o-mini")
#=> %LLMModels.Model{id: "gpt-4o-mini", provider: :openai, ...}
```

## Quick Start

```elixir
# Get a model and read metadata
{:ok, model} = LLMModels.model("openai:gpt-4o-mini")
model.capabilities.tools.enabled  #=> true
model.cost.input                  #=> 0.15  (per 1M tokens)
model.limits.context              #=> 128_000

# Select a model by capabilities (returns {provider, id})
{:ok, {provider, id}} = LLMModels.select(
  require: [chat: true, tools: true, json_native: true],
  prefer:  [:openai, :anthropic]
)
{:ok, model} = LLMModels.model({provider, id})

# List providers
LLMModels.providers()
#=> [%LLMModels.Provider{id: :anthropic, ...}, %LLMModels.Provider{id: :openai, ...}]

# Check availability (allow/deny filters)
LLMModels.allowed?("openai:gpt-4o-mini") #=> true
```

## API Cheatsheet

- **`model/1`** — `"provider:model"` → `%Model{}`
- **`select/1`** — pick best `{provider, id}` by capabilities
- **`providers/0`** — list `%Provider{}` structs
- **`list_providers/0`** — provider IDs as atoms
- **`get_provider/1`** — `%Provider{}` by ID
- **`allowed?/1`** — check availability for a spec or tuple
- **`reload/0`**, **`epoch/0`**, **`snapshot/0`** — lifecycle utilities

See the full function docs in [hexdocs](https://hexdocs.pm/llm_models).

## Data Structures

### Provider

```elixir
%LLMModels.Provider{
  id: :openai,
  name: "OpenAI",
  base_url: "https://api.openai.com",
  env: ["OPENAI_API_KEY"],
  doc: "https://platform.openai.com/docs",
  extra: %{}
}
```

### Model

```elixir
%LLMModels.Model{
  id: "gpt-4o-mini",
  provider: :openai,
  name: "GPT-4o mini",
  family: "gpt-4o",
  limits: %{context: 128_000, output: 16_384},
  cost: %{input: 0.15, output: 0.60},
  capabilities: %{
    chat: true,
    tools: %{enabled: true, streaming: true},
    json: %{native: true, schema: true},
    streaming: %{text: true, tool_calls: true}
  },
  tags: [],
  deprecated?: false,
  aliases: [],
  extra: %{}
}
```

## Configuration

The packaged snapshot loads automatically at app start. Optional runtime filters and preferences:

```elixir
# config/runtime.exs
config :llm_models,
  prefer: [:openai, :anthropic],     # provider preference order
  allow: %{openai: :all},            # allow by provider or wildcard list
  deny:  %{openai: ["*-preview"]}    # deny patterns override allow
```

Reload during development:

```elixir
:ok = LLMModels.reload()
```

## Updating Model Data

Snapshot is shipped with the library. To rebuild with fresh data:

```bash
# Fetch upstream data (optional)
mix llm_models.pull

# Run ETL and write snapshot.json
mix llm_models.build
```

See the [Sources & Engine](guides/sources-and-engine.md) guide for details.

## Using with ReqLLM

Designed to power [ReqLLM](https://github.com/agentjido/req_llm), but fully standalone. Use `model_spec` + `model/1` to retrieve metadata for API calls.

## Docs & Guides

- [Using the Data](guides/using-the-data.md) — Runtime API and querying
- [Sources & Engine](guides/sources-and-engine.md) — ETL pipeline, data sources, precedence
- [Schema System](guides/schema-system.md) — Zoi validation and data structures
- [Release Process](guides/release-process.md) — Snapshot-based releases

## License

MIT License - see LICENSE file for details.
