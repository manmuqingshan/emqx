defmodule Mix.Tasks.Emqx.Eunit do
  use Mix.Task

  alias Mix.Tasks.Emqx.Ct, as: ECt

  # todo: invoke the equivalent of `make merge-config` as a requirement...
  @requirements ["compile", "loadpaths"]

  @impl true
  def run(args) do
    Enum.each([:common_test, :eunit, :mnesia], &ECt.add_to_path_and_cache/1)

    ECt.ensure_whole_emqx_project_is_loaded()
    ECt.unload_emqx_applications!()

    {_, 0} = System.cmd("epmd", ["-daemon"])
    node_name = :"test@127.0.0.1"
    :net_kernel.start([node_name, :longnames])

    # unmangle PROFILE env because some places (`:emqx_conf.resolve_schema_module`) expect
    # the version without the `-test` suffix.
    System.fetch_env!("PROFILE")
    |> String.replace_suffix("-test", "")
    |> then(& System.put_env("PROFILE", &1))

    EMQX.Mix.Utils.clear_screen()

    ECt.maybe_start_cover()
    if ECt.cover_enabled?(), do: ECt.cover_compile_files()

    opts = parse_args!(args)

    opts
    |> discover_tests()
    |> :eunit.test(
      verbose: true,
      print_depth: 100
    )
    |> case do
       :ok ->
         if ECt.cover_enabled?(), do: ECt.write_coverdata(opts)
         :ok

       :error ->
         Mix.raise("errors found in tests")
     end
  end

  defp add_to_path_and_cache(lib_name) do
    :code.lib_dir()
    |> Path.join("#{lib_name}-*")
    |> Path.wildcard()
    |> hd()
    |> Path.join("ebin")
    |> to_charlist()
    |> :code.add_path(:cache)
  end

  defp parse_args!(args) do
    {opts, _rest} = OptionParser.parse!(
      args,
      strict: [
        cover_export_name: :string,
        cases: :string,
        modules: :string,
      ]
    )
    cases =
      opts
      |> get_name_list(:cases)
      |> Enum.flat_map(&resolve_test_fns!/1)
    modules =
      opts
      |> get_name_list(:modules)
      |> Enum.map(&String.to_atom/1)

    %{
      cover_export_name: Keyword.get(opts, :cover_export_name, "eunit"),
      cases: cases,
      modules: modules,
    }
  end

  defp get_name_list(opts, key) do
    opts
    |> Keyword.get(key, "")
    |> String.split(",", trim: true)
  end

  defp resolve_test_fns!(mod_fn_str) do
    {mod, fun} = case String.split(mod_fn_str, ":") do
      [mod, fun] ->
        {String.to_atom(mod), String.to_atom(fun)}
      _ ->
        Mix.raise("Bad test case spec; must of `MOD:FUN` form.  Got: #{mod_fn_str}`")
    end
    if not has_test_case?(mod, fun) do
      Mix.raise("Module #{mod} does not export test case #{fun}")
    end

    if to_string(fun) =~ ~r/_test_$/ do
      apply(mod, fun, [])
    else
      [Function.capture(mod, fun, 0)]
    end
  end

  defp has_test_case?(mod, fun) do
    try do
      mod.module_info(:functions)
      |> Enum.find(& &1 == {fun, 0})
      |> then(& !! &1)
    rescue
      UndefinedFunctionError -> false
    end
  end

  defp discover_tests(%{cases: [], modules: []} = _opts) do
    Mix.Dep.Umbrella.cached()
    |> Enum.map(& {:application, &1.app})
  end
  defp discover_tests(%{cases: cases, modules: modules}) do
    Enum.concat(
      [
        cases,
        Enum.map(modules, & {:module, &1})
      ]
    )
  end
end
