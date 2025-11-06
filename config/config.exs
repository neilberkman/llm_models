import Config

# LLM Models configuration
config :llm_models,
  # Default sources for loading model metadata (first = lowest precedence, last = highest)
  sources: [
    {LLMModels.Sources.ModelsDev, %{}},
    {LLMModels.Sources.Local, %{dir: "priv/llm_models"}},
    {LLMModels.Sources.Config,
     %{overrides: Application.compile_env(:llm_models, :overrides, %{})}}
  ],

  # Cache directory for remote sources
  models_dev_cache_dir: "priv/llm_models/upstream",
  upstream_cache_dir: "priv/llm_models/upstream"

if Mix.env() == :dev do
  config :git_ops,
    mix_project: LLMModels.MixProject,
    changelog_file: "CHANGELOG.md",
    repository_url: "https://github.com/agentjido/llm_models",
    manage_mix_version?: false,
    manage_readme_version: false,
    version_tag_prefix: "v"
end

# Import environment-specific config
if File.exists?("config/#{Mix.env()}.exs") do
  import_config "#{Mix.env()}.exs"
end
