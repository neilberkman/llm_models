# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- changelog -->

## [Unreleased]

### Added

- AWS Bedrock inference profile aliases for cross-region routing (us., eu., ap., ca., global. prefixes)
  - anthropic.claude-haiku-4-5-20251001-v1:0
  - anthropic.claude-sonnet-4-5-20250929-v1:0
  - anthropic.claude-opus-4-1-20250805-v1:0
  - meta.llama3-2-3b-instruct-v1:0

### Fixed

- Model spec parsing now handles ambiguous formats (specs with both `:` and `@` separators) by attempting provider validation to determine the correct format
- Removed overly strict character validation that rejected `@` in model IDs when using colon format and `:` in model IDs when using @ format

## [2025.11.14-preview] - 2025-11-14

### Added

- `LLMDB.Model.format_spec/1` function for converting model struct to provider:model string format
- Zai Coder provider and GLM models support
- Enhanced cost schema with granular multimodal and reasoning pricing fields:
  - `reasoning`: Cost per 1M reasoning/thinking tokens for models like o1, Grok-4
  - `input_audio`/`output_audio`: Separate audio input/output costs (e.g., Gemini 2.5 Flash, Qwen-Omni)
  - `input_video`/`output_video`: Video input/output cost support for future models
- ModelsDev source transformer now captures all cost fields from models.dev data
- OpenRouter source transformer maps `internal_reasoning` field to `reasoning` cost

### Changed

- Updated Zoi dependency to version 0.10.6
- Refactored loader to use dynamic snapshot retrieval
- Disabled schema validation in snapshot.json and TOML source files

### Fixed

- Cleaned up code quality issues
