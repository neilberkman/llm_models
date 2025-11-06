defmodule LLMModels.ConfigTest do
  use ExUnit.Case, async: false
  doctest LLMModels.Config

  setup do
    original_config = Application.get_all_env(:llm_models)

    on_exit(fn ->
      Application.put_all_env(llm_models: original_config)
    end)

    :ok
  end

  describe "get/0" do
    test "returns defaults when no config set" do
      Application.delete_env(:llm_models, :compile_embed)
      Application.delete_env(:llm_models, :allow)
      Application.delete_env(:llm_models, :deny)
      Application.delete_env(:llm_models, :prefer)

      config = LLMModels.Config.get()

      assert config.compile_embed == false
      assert config.allow == :all
      assert config.deny == %{}
      assert config.prefer == []
    end

    test "returns configured values" do
      Application.put_env(:llm_models, :compile_embed, true)
      Application.put_env(:llm_models, :prefer, [:openai, :anthropic])

      config = LLMModels.Config.get()

      assert config.compile_embed == true
      assert config.prefer == [:openai, :anthropic]
    end
  end

  describe "compile_filters/2" do
    test "compiles :all allow pattern" do
      result = LLMModels.Config.compile_filters(:all, %{})

      assert result.allow == :all
      assert result.deny == %{}
    end

    test "compiles provider-specific allow patterns" do
      allow = %{openai: ["gpt-4*", "gpt-3*"]}
      deny = %{}

      result = LLMModels.Config.compile_filters(allow, deny)

      assert is_map(result.allow)
      assert Map.has_key?(result.allow, :openai)
      assert length(result.allow.openai) == 2
      assert Enum.all?(result.allow.openai, &match?(%Regex{}, &1))
    end

    test "compiles deny patterns" do
      allow = :all
      deny = %{openai: ["gpt-5*"], anthropic: ["claude-2*"]}

      result = LLMModels.Config.compile_filters(allow, deny)

      assert result.allow == :all
      assert is_map(result.deny)
      assert Map.has_key?(result.deny, :openai)
      assert Map.has_key?(result.deny, :anthropic)
      assert Enum.all?(result.deny.openai, &match?(%Regex{}, &1))
      assert Enum.all?(result.deny.anthropic, &match?(%Regex{}, &1))
    end

    test "compiles both allow and deny patterns" do
      allow = %{openai: ["gpt-4*"]}
      deny = %{openai: ["gpt-4-32k"]}

      result = LLMModels.Config.compile_filters(allow, deny)

      assert is_map(result.allow)
      assert is_map(result.deny)
      assert length(result.allow.openai) == 1
      assert length(result.deny.openai) == 1
    end

    test "handles empty patterns" do
      result = LLMModels.Config.compile_filters(%{}, %{})

      assert result.allow == %{}
      assert result.deny == %{}
    end

    test "compiled patterns match correctly" do
      allow = %{openai: ["gpt-4*"]}
      result = LLMModels.Config.compile_filters(allow, %{})

      [pattern] = result.allow.openai

      assert Regex.match?(pattern, "gpt-4")
      assert Regex.match?(pattern, "gpt-4-turbo")
      refute Regex.match?(pattern, "gpt-3.5-turbo")
    end
  end

  describe "integration tests" do
    test "full config workflow" do
      Application.put_env(:llm_models, :compile_embed, true)
      Application.put_env(:llm_models, :allow, %{openai: ["gpt-4*"]})
      Application.put_env(:llm_models, :deny, %{openai: ["gpt-4-32k"]})
      Application.put_env(:llm_models, :prefer, [:openai, :anthropic])

      config = LLMModels.Config.get()
      filters = LLMModels.Config.compile_filters(config.allow, config.deny)

      assert config.compile_embed == true
      assert config.prefer == [:openai, :anthropic]

      assert is_map(filters.allow)
      assert is_map(filters.deny)
      assert Map.has_key?(filters.allow, :openai)
      assert Map.has_key?(filters.deny, :openai)
    end
  end
end
