defmodule ShhAi.DeploymentTest do
  # async: false — the build-profile cases mutate SHHAI_SLIM in the
  # process environment (mix.exs reads it at call time).
  use ExUnit.Case, async: false

  @env_example_path ".env.example"
  @config_source "lib/shh_ai/config.ex"

  describe "build-flag dependency profile" do
    test "the default profile ships the ML stack" do
      System.delete_env("SHHAI_SLIM")

      names = ShhAi.MixProject.ml_deps() |> Enum.map(&elem(&1, 0))

      assert :bumblebee in names
      assert :nx in names
      assert :exla in names
      refute ShhAi.MixProject.slim_build?()
    end

    test "the slim profile drops the ML dependencies" do
      System.put_env("SHHAI_SLIM", "true")
      on_exit(fn -> System.delete_env("SHHAI_SLIM") end)

      assert ShhAi.MixProject.slim_build?()
      assert ShhAi.MixProject.ml_deps() == []
    end
  end

  describe ".env.example" do
    test "documents every environment variable ShhAi.Config reads" do
      example = File.read!(@env_example_path)
      documented = documented_keys(example)

      for var <- config_env_vars() do
        assert var in documented,
               "ShhAi.Config reads #{var} but #{@env_example_path} does not document it"
      end
    end

    test "documents the provider instance surface" do
      example = File.read!(@env_example_path)
      documented = documented_keys(example)

      provider_vars =
        for provider <- ["OPENAI", "ANTHROPIC", "OLLAMA"],
            suffix <- ["ENABLED", "API_KEY", "BASE_URL", "TIMEOUT"] do
          "PROVIDER_#{provider}_1_#{suffix}"
        end

      for var <- provider_vars do
        assert var in documented, "#{@env_example_path} is missing #{var}"
      end
    end

    test "documents the offline-NER build/runtime knobs" do
      example = File.read!(@env_example_path)

      assert "BUMBLEBEE_OFFLINE" in documented_keys(example)
      assert "BUMBLEBEE_CACHE_DIR" in documented_keys(example)
    end
  end

  describe "container artifacts" do
    test "the image is multi-stage, rootless, and runs under tini" do
      dockerfile = File.read!("Dockerfile")

      assert dockerfile =~ "AS build"
      assert dockerfile =~ "AS runtime"
      assert dockerfile =~ "USER nonroot"
      assert dockerfile =~ ~s(ENTRYPOINT ["tini")
    end

    test "compose runs the proxy read-only with scratch under /tmp" do
      compose = File.read!("docker-compose.yml")

      assert compose =~ "read_only: true"
      assert compose =~ "- /tmp"
      assert compose =~ "audit-data:/data"
    end

    test "the entrypoint migrates only when Audit Mode is on" do
      entrypoint = File.read!("rel/overlays/bin/docker-entrypoint")

      assert entrypoint =~ ~s(AUDIT_MODE:-false)
      assert entrypoint =~ "bin/migrate"
    end
  end

  # Every literal env-var read in ShhAi.Config: `System.get_env("LITERAL")`,
  # an `env_*("LITERAL", ...)` helper call, or `app_or_env(:key, "LITERAL", ...)`.
  # Provider vars are dynamic (`PROVIDER_<TYPE>_<N>_<KEY>`) and asserted
  # separately.
  defp config_env_vars do
    source = File.read!(@config_source)

    literal = ~r/(?:System\.get_env|env_bool|env_string|env_int|env_float|env_csv|env_enum)\("([A-Z0-9_]+)"/
    app_or_env = ~r/app_or_env\(\s*:\w+,\s*"([A-Z0-9_]+)"/

    (scan(source, literal) ++ scan(source, app_or_env)) |> Enum.uniq()
  end

  defp scan(source, regex) do
    Regex.scan(regex, source) |> Enum.map(fn [_, name] -> name end)
  end

  defp documented_keys(example) do
    example
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^([A-Z0-9_]+)=/, line) do
        [_, key] -> [key]
        _ -> []
      end
    end)
  end
end
