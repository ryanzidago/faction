# Generates a deterministic Phoenix app with a given number of application
# BEAMs, lines of code and routes, for scale runs. The defaults match the scale
# target in PRINCIPLES.md (~10k BEAMs, ~3M lines, ~3k routes). The same flags
# always write the same files. Faction never compiles it; `mix compile` does.
#
#   elixir validation/synthetic_app.exs --beams 10000 --lines 3000000 --routes 3000 --seed 1 --out _scratch/synthetic
#   cd _scratch/synthetic && mix compile
#
# It builds the app the way a team would: `mix phx.new` (the pinned phx_new
# archive) and `phx.gen.auth`, then Phoenix's own generators for every resource
# (`phx.gen.live`/`html`/`json` for the ones with routes, `phx.gen.context` for
# the rest, run in one process by synthetic_scaffold.exs). It then grows that
# scaffold, the way years of work would: libraries a large app uses (Oban,
# Absinthe, Localize), extra modules per context (among them Oban jobs,
# GenServers under per-namespace Supervisors, GraphQL types and resolvers) and
# extra functions in contexts, LiveViews and HTML modules, up to exactly
# --beams and --lines.
#
# Next to the app it writes the oracle that check_synthetic.sql compares
# Faction's output with: manifest.json (expected counts) and
# expected_calls.jsonl (every call into a context module the generator wrote
# from another context, a query module, a GenServer, an Oban job or a
# resolver, with its line).
defmodule Synth.Gen do
  @phx_new "1.8.14"
  @contexts_per_part 200
  # BEAMs of `phx.new` plus `phx.gen.auth --live`, and the routes they declare
  # (plus the GraphQL endpoint this script adds).
  @skeleton_beams 27
  @skeleton_routes 13 + 1
  # Libraries a large app adds beyond `phx.new`.
  @deps [
    ~s({:oban, "~> 2.24"}),
    ~s({:absinthe, "~> 1.12"}),
    ~s({:absinthe_plug, "~> 1.5"}),
    ~s({:localize, "~> 1.3"})
  ]
  # The generators' FallbackController and ChangesetJSON, written with the
  # first JSON resource.
  @json_shared_beams 2
  @shared_modules [
    "Synth.Worker",
    "Synth.Describable",
    "Synth.Macros",
    "SynthWeb.GraphQLContext",
    "SynthWeb.Schema"
  ]
  # BEAMs with no module declaration: Absinthe compiles SynthWeb.Schema into
  # SynthWeb.Schema.Compiled.
  @generated_beams 1
  @kind_beams %{"live" => 4, "html" => 3, "json" => 3, "context" => 1}
  @kind_routes %{"live" => 4, "html" => 8, "json" => 6, "context" => 0}
  # The modules this script adds to a context: kind, BEAMs, and the share of
  # contexts that have it. A context gets them in this order when the budget
  # runs short. Every namespace also gets a Supervisor for its GenServers.
  @extra_kinds [
    {:query, 1, 1.0},
    {:worker, 1, 1.0},
    {:describable, 1, 1.0},
    {:hooks, 1, 1.0},
    {:link, 1, 1.0},
    {:job, 1, 0.5},
    {:graphql, 2, 0.25},
    {:server, 1, 0.15}
  ]
  @resources_per_context 3.5
  @nouns ~w(Invoice Order Shipment Customer Product Ticket Report Payment Account
            Project Task Comment Review Contract Vendor Warehouse Booking Campaign
            Lead Asset Claim Device Receipt Budget Survey Article)
  @fields [
    {"title", "string"},
    {"code", "string"},
    {"status", "string"},
    {"description", "text"},
    {"notes", "text"},
    {"quantity", "integer"},
    {"position", "integer"},
    {"active", "boolean"},
    {"archived", "boolean"},
    {"starts_on", "date"},
    {"due_on", "date"},
    {"amount", "decimal"},
    {"price", "decimal"}
  ]
  # Extra lines are spread over contexts with a long tail (Pareto), capped so
  # no module grows past about @max_module_lines.
  @pareto_alpha 1.2
  @max_module_lines 10_000
  # Share of a context's extra lines for each host module, with and without
  # web modules (LiveView Index and HTML modules, split evenly between them).
  @shares_web %{context: 0.25, query: 0.15, web: 0.6}
  @shares %{context: 0.6, query: 0.4, web: 0.0}

  @type resource :: %{
          index: pos_integer(),
          kind: String.t(),
          schema: String.t(),
          singular: String.t(),
          plural: String.t(),
          fields: [{String.t(), String.t()}]
        }
  @type context :: %{
          part: pos_integer(),
          index: pos_integer(),
          global: non_neg_integer(),
          resources: [resource()],
          extras: [atom()]
        }
  @type layout :: %{
          digits: pos_integer(),
          contexts: [context()],
          by_index: tuple(),
          parts: pos_integer()
        }
  @type target :: {String.t(), String.t(), arity()}
  @type plan :: %{
          context: context(),
          calls: [target()],
          apply_target: target(),
          capture_target: target(),
          link_target: String.t()
        }
  # {caller function, caller arity, callee module, callee function, callee arity, kind}
  @type edge :: {String.t(), arity(), String.t(), String.t(), arity(), String.t()}
  # A source line, or one that holds a call recorded in the oracle.
  @type line :: String.t() | {String.t(), edge()}
  # A module, its file, its lines and how many lines the file had before.
  @type source :: {String.t(), Path.t(), [line()], non_neg_integer()}
  @type host :: :logic | {:web, context(), resource()}
  @type stats :: %{
          lines: non_neg_integer(),
          edges: non_neg_integer(),
          largest: {non_neg_integer(), String.t() | nil}
        }

  @spec main([String.t()]) :: :ok
  def main(argv) do
    {opts, [], []} =
      OptionParser.parse(argv,
        strict: [beams: :integer, lines: :integer, routes: :integer, seed: :integer, out: :string]
      )

    out = Keyword.fetch!(opts, :out) |> Path.expand()
    beams = Keyword.get(opts, :beams, 10_000)
    target = Keyword.get(opts, :lines, 3_000_000)
    routes = Keyword.get(opts, :routes, 3_000)
    seed = Keyword.get(opts, :seed, 1)

    prepare!(out)
    skeleton!(out)
    :rand.seed(:exsss, seed)
    layout = layout(beams, routes)
    plans = Enum.map(layout.contexts, &plan(layout, &1))
    scaffold!(out, layout)

    base =
      scaffold_lines(out) +
        (out
         |> sources(layout, plans, %{})
         |> Enum.reduce(0, fn {_, _, lines, before}, acc -> acc + length(lines) - before end))

    if target < base do
      IO.puts(
        :stderr,
        "--lines #{target} is below the #{base} lines the scaffold needs; writing #{base}"
      )
    end

    budgets = budgets(plans, max(target - base, 0))
    edges = File.open!(Path.join(out, "expected_calls.jsonl"), [:write, :utf8])

    stats =
      out
      |> sources(layout, plans, budgets)
      |> Enum.reduce(%{lines: 0, edges: 0, largest: {0, nil}}, &write_source!(out, &1, edges, &2))

    File.close(edges)
    check!(out, beams, max(target, base))

    resources = Enum.flat_map(layout.contexts, & &1.resources)
    count_kind = fn kind -> Enum.count(resources, &(&1.kind == kind)) end
    count_extra = fn kind -> Enum.count(layout.contexts, &(kind in &1.extras)) end
    {largest_lines, largest} = stats.largest

    manifest = [
      seed: seed,
      modules: beams,
      lines: max(target, base),
      routes: @skeleton_routes + Enum.sum_by(resources, &@kind_routes[&1.kind]),
      contexts: length(layout.contexts),
      resources: length(resources),
      live_views: 4 + 3 * count_kind.("live"),
      largest_module: largest,
      largest_module_lines: largest_lines,
      # Auth's User and UserToken, one per resource, and the Link schemas.
      schemas: 2 + length(resources) + count_extra.(:link),
      workers: count_extra.(:worker),
      jobs: count_extra.(:job),
      servers: count_extra.(:server),
      # The namespaces' Supervisors and phx.new's SynthWeb.Telemetry.
      supervisors: layout.parts + 1,
      graphql_contexts: count_extra.(:graphql),
      dynamic_calls: length(layout.contexts),
      edges: stats.edges
    ]

    write!(out, "manifest.json", [encode(manifest), "\n"])

    IO.puts(
      "#{beams} modules, #{manifest[:lines]} lines, #{manifest[:routes]} routes " <>
        "(largest #{largest}, #{largest_lines} lines): #{out}"
    )
  end

  # A JSON object with keys in the given order, so output is byte-stable.
  @spec encode(keyword()) :: iodata()
  defp encode(fields) do
    [
      "{",
      Enum.map_intersperse(fields, ",", fn {key, value} ->
        [JSON.encode!(Atom.to_string(key)), ":", JSON.encode!(value)]
      end),
      "}"
    ]
  end

  # Regenerates only a directory this script wrote before, keeping its deps and
  # _build so a rerun doesn't refetch and recompile them.
  @spec prepare!(Path.t()) :: :ok
  defp prepare!(out) do
    cond do
      not File.exists?(out) or File.ls!(out) == [] ->
        File.mkdir_p!(out)

      File.exists?(Path.join(out, "manifest.json")) ->
        for entry <- File.ls!(out), entry not in ["deps", "_build"] do
          File.rm_rf!(Path.join(out, entry))
        end

      true ->
        raise "#{out} is not empty and has no manifest.json; refusing to overwrite it"
    end

    :ok
  end

  # `phx.new` and `phx.gen.auth`, with the random secrets replaced, @deps and
  # their config added, and the dependencies pinned by synthetic_app.lock.
  @spec skeleton!(Path.t()) :: :ok
  defp skeleton!(out) do
    version = shell!("mix phx.new --version", File.cwd!())

    unless version =~ "v#{@phx_new}" do
      raise "needs the phx_new #{@phx_new} archive, found: #{version}"
    end

    shell!(
      "yes | mix phx.new #{out} --app synth --module Synth --no-assets --no-esbuild " <>
        "--no-tailwind --no-dashboard --no-install",
      Path.dirname(out)
    )

    for file <- ~w(config/config.exs config/dev.exs config/test.exs lib/synth_web/endpoint.ex) do
      path = Path.join(out, file)
      fixed = ~s(\\1: "#{String.duplicate("synthetic", 8)}")

      File.write!(
        path,
        Regex.replace(~r/(secret_key_base|signing_salt): "[^"]*"/, File.read!(path), fixed)
      )
    end

    edit!(out, "mix.exs", ~s({:bandit, "~> 1.5"}), fn anchor ->
      Enum.join([anchor | @deps], ",\n      ")
    end)

    edit!(out, "config/config.exs", "# Import environment specific config", fn anchor ->
      """
      config :synth, Oban,
        engine: Oban.Engines.Basic,
        queues: [default: 10, sync: 20],
        repo: Synth.Repo

      config :localize, default_locale: :en, supported_locales: [:en, :fr, :de]

      #{anchor}\
      """
    end)

    edit!(out, "config/test.exs", "config :synth, Synth.Mailer", fn anchor ->
      "config :synth, Oban, testing: :manual\n\n#{anchor}"
    end)

    File.cp!(Path.join(__DIR__, "synthetic_app.lock"), Path.join(out, "mix.lock"))
    shell!("mix deps.get", out)
    shell!("yes | mix phx.gen.auth Accounts User users --live", out)
    shell!("mix deps.get", out)
    :ok
  end

  # Replaces the one occurrence of `anchor` in a generated file.
  @spec edit!(Path.t(), Path.t(), String.t(), (String.t() -> String.t())) :: :ok
  defp edit!(out, file, anchor, replace) do
    path = Path.join(out, file)
    [before, rest] = path |> File.read!() |> String.split(anchor, parts: 2)
    File.write!(path, before <> replace.(anchor) <> rest)
  end

  @spec shell!(String.t(), Path.t()) :: String.t()
  defp shell!(command, dir) do
    case System.shell(command, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "#{command} exited with #{status}:\n#{output}"
    end
  end

  # Runs the generators for every resource, writes their routes into the one
  # router, and drops what isn't application code (tests, migrations).
  @spec scaffold!(Path.t(), layout()) :: :ok
  defp scaffold!(out, layout) do
    tasks =
      for context <- layout.contexts, resource <- context.resources do
        ctx = "#{part_name(layout, context.part)}.Ctx#{context.index}"

        fields =
          Enum.map([{"name", "string"} | resource.fields], fn {name, type} ->
            "#{name}:#{type}"
          end)

        args =
          [ctx, resource.schema, resource.plural | fields] ++ ["--merge-with-existing-context"]

        case resource.kind do
          "context" -> ["phx.gen.context", args]
          kind -> ["phx.gen.#{kind}", args ++ ["--web", part_name(layout, context.part)]]
        end
      end

    plan = Path.join(out, "scaffold.json")
    File.write!(plan, JSON.encode!(tasks))

    {_, 0} =
      System.cmd("mix", ["run", "--no-start", Path.join(__DIR__, "synthetic_scaffold.exs"), plan],
        cd: out,
        stderr_to_stdout: true,
        into: IO.stream()
      )

    File.rm!(plan)
    File.rm_rf!(Path.join(out, "test"))
    File.rm_rf!(Path.join(out, "priv/repo/migrations"))

    router = Path.join(out, "lib/synth_web/router.ex")
    head = router |> File.read!() |> String.trim_trailing() |> String.trim_trailing("end")
    File.write!(router, head <> routes(layout))

    edit!(out, "lib/synth/application.ex", "      # Start a worker by calling", fn anchor ->
      supervisors =
        for part <- 1..layout.parts, do: "      Synth.#{part_name(layout, part)}.Supervisor,\n"

      "      {Oban, Application.fetch_env!(:synth, Oban)},\n#{supervisors}#{anchor}"
    end)
  end

  # The generators print the routes to add; this adds them, as a team would:
  # LiveViews in one authenticated live_session, HTML resources in the
  # authenticated browser scope, JSON resources and GraphQL under /api.
  @spec routes(layout()) :: String.t()
  defp routes(layout) do
    routed =
      for context <- layout.contexts, resource <- context.resources do
        part = part_name(layout, context.part)
        {resource.kind, part, "/#{String.downcase(part)}/#{resource.plural}", resource.schema}
      end

    live =
      for {"live", part, path, schema} <- routed, into: "" do
        """
              live "#{path}", #{part}.#{schema}Live.Index, :index
              live "#{path}/new", #{part}.#{schema}Live.Form, :new
              live "#{path}/:id", #{part}.#{schema}Live.Show, :show
              live "#{path}/:id/edit", #{part}.#{schema}Live.Form, :edit
        """
      end

    html =
      for {"html", part, path, schema} <- routed, into: "" do
        "    resources \"#{path}\", #{part}.#{schema}Controller\n"
      end

    json =
      for {"json", part, path, schema} <- routed, into: "" do
        "    resources \"#{path}\", #{part}.#{schema}Controller, except: [:new, :edit]\n"
      end

    """

      scope "/", SynthWeb do
        pipe_through [:browser, :require_authenticated_user]

        live_session :resources,
          on_mount: [{SynthWeb.UserAuth, :require_authenticated}] do
    #{live}    end

    #{html}  end

      scope "/api", SynthWeb do
        pipe_through [:api]

    #{json}  end

      pipeline :graphql do
        plug SynthWeb.GraphQLContext
      end

      scope "/api" do
        pipe_through [:api, :graphql]

        forward "/graphql", Absinthe.Plug, schema: SynthWeb.Schema
      end
    end
    """
  end

  @spec scaffold_lines(Path.t()) :: non_neg_integer()
  defp scaffold_lines(out),
    do: Enum.sum_by(lib_files(out), &(&1 |> File.read!() |> lines() |> length()))

  @spec lib_files(Path.t()) :: [Path.t()]
  defp lib_files(out), do: Path.wildcard(Path.join(out, "lib/**/*.{ex,heex}"))

  # Every module declaration compiles to one BEAM, and @generated_beams more
  # have none, so the count is checked without compiling.
  @spec check!(Path.t(), pos_integer(), pos_integer()) :: :ok
  defp check!(out, beams, lines) do
    sources = Enum.map(lib_files(out), &File.read!/1)

    declared =
      Enum.sum_by(sources, &length(Regex.scan(~r/^\s*(defmodule|defprotocol|defimpl) /m, &1)))

    written = Enum.sum_by(sources, &length(lines(&1)))

    if declared + @generated_beams != beams or written != lines do
      raise "wrote #{declared + @generated_beams} modules and #{written} lines, " <>
              "planned #{beams} and #{lines}"
    end

    :ok
  end

  # Splits the BEAM budget. Routed resources come first (enough for --routes),
  # then contexts, each with its drawn extra modules, and context-only
  # resources for the rest; with too few BEAMs left, the extra modules shrink
  # instead.
  @spec layout(pos_integer(), pos_integer()) :: layout()
  defp layout(beams, routes) do
    routed = routed_kinds(routes - @skeleton_routes, [])

    budget =
      beams - @skeleton_beams - length(@shared_modules) - @generated_beams -
        if("json" in routed, do: @json_shared_beams, else: 0) -
        Enum.sum_by(routed, &@kind_beams[&1])

    per_context = 1 + Enum.sum_by(@extra_kinds, fn {_, beams, share} -> beams * share end)
    count = max(1, round((budget + length(routed)) / (per_context + @resources_per_context)))
    parts = ceil(count / @contexts_per_part)
    # One Supervisor per namespace.
    budget = budget - parts

    wanted =
      for {kind, beams, share} <- @extra_kinds,
          global <- 0..(count - 1),
          :rand.uniform() < share,
          do: {kind, beams, global}

    context_only = max(budget - count - Enum.sum_by(wanted, &elem(&1, 1)), 0)

    # The first extra modules that fit; a BEAM left over becomes a resource.
    {taken, left} =
      Enum.flat_map_reduce(wanted, budget - count - context_only, fn {kind, beams, global},
                                                                     room ->
        if beams <= room, do: {[{global, kind}], room - beams}, else: {[], room}
      end)

    context_only = context_only + max(left, 0)

    if left < 0 or length(routed) + context_only < count do
      raise "--beams #{beams} doesn't fit --routes #{routes}"
    end

    extras = Enum.group_by(taken, &elem(&1, 0), &elem(&1, 1))

    resources =
      (routed ++ List.duplicate("context", context_only))
      |> Enum.shuffle()
      |> Enum.with_index(1)
      |> Enum.map(fn {kind, index} -> resource(kind, index) end)

    # One resource per context, then the rest at random, so sizes vary.
    {first, rest} = Enum.split(resources, count)

    owners =
      Enum.with_index(first, fn _, global -> global end) ++
        Enum.map(rest, fn _ -> :rand.uniform(count) - 1 end)

    by_context = resources |> Enum.zip(owners) |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))

    contexts =
      for global <- 0..(count - 1) do
        %{
          part: div(global, @contexts_per_part) + 1,
          index: rem(global, @contexts_per_part) + 1,
          global: global,
          resources: Enum.sort_by(by_context[global], & &1.index),
          extras: Map.get(extras, global, [])
        }
      end

    %{
      digits: max(2, parts |> Integer.to_string() |> String.length()),
      contexts: contexts,
      by_index: List.to_tuple(contexts),
      parts: parts
    }
  end

  # Kinds of routed resources, half LiveViews, until they declare `routes`.
  @spec routed_kinds(integer(), [String.t()]) :: [String.t()]
  defp routed_kinds(routes, acc) when routes <= 0, do: Enum.reverse(acc)

  defp routed_kinds(routes, acc) do
    kind = Enum.at(["live", "live", "html", "json"], :rand.uniform(4) - 1)
    routed_kinds(routes - @kind_routes[kind], [kind | acc])
  end

  @spec resource(String.t(), pos_integer()) :: resource()
  defp resource(kind, index) do
    noun = Enum.at(@nouns, rem(index, length(@nouns)))

    %{
      index: index,
      kind: kind,
      schema: "#{noun}#{index}",
      singular: Macro.underscore("#{noun}#{index}"),
      plural: "#{Macro.underscore(noun)}s_#{index}",
      fields: @fields |> Enum.take_random(1 + :rand.uniform(4)) |> Enum.sort()
    }
  end

  # Every random choice a context's fixed code needs, drawn up front so
  # rendering it is pure (it is rendered twice: to count, then to write).
  @spec plan(layout(), context()) :: plan()
  defp plan(layout, context) do
    %{
      context: context,
      calls: for(_ <- 1..3, do: target(layout, context, :any)),
      apply_target: target(layout, context, :list),
      capture_target: target(layout, context, :get),
      link_target: schema_name(layout, pick(layout, context), 0)
    }
  end

  # A generated function of another context: list_<plural>(scope) or
  # get_<singular>!(scope, id).
  @spec target(layout(), context(), :list | :get | :any) :: target()
  defp target(layout, context, which) do
    other = pick(layout, context)
    resource = Enum.random(other.resources)
    which = if which == :any, do: Enum.random([:list, :get]), else: which
    name = context_name(layout, other)

    case which do
      :list -> {name, "list_#{resource.plural}", 1}
      :get -> {name, "get_#{resource.singular}!", 2}
    end
  end

  # Another context, log-uniform over the global index, so low indexes become
  # hubs with large fan-in, as in a real app.
  @spec pick(layout(), context()) :: context()
  defp pick(layout, self) do
    limit = tuple_size(layout.by_index)
    global = min(limit - 1, trunc(:math.pow(limit, :rand.uniform())) - 1)
    target = elem(layout.by_index, global)
    if target == self and limit > 1, do: pick(layout, self), else: target
  end

  # Extra lines per context (by global index): Pareto weights scaled to the
  # budget, capped, with the integer remainder going to the lowest indexes so
  # the total is exact.
  @spec budgets([plan()], non_neg_integer()) :: %{non_neg_integer() => non_neg_integer()}
  defp budgets(_plans, 0), do: %{}

  defp budgets(plans, budget) do
    weights =
      Enum.map(plans, &{&1.context.global, :math.pow(1.0 - :rand.uniform(), -1 / @pareto_alpha)})

    shares =
      weights
      |> cap(budget, trunc(@max_module_lines / @shares.context))
      |> Enum.sort()
      |> Enum.map(fn {global, share} -> {global, trunc(share)} end)

    remainder = budget - Enum.sum_by(shares, &elem(&1, 1))

    shares
    |> Enum.with_index(fn {global, share}, i ->
      {global, share + if(i < remainder, do: 1, else: 0)}
    end)
    |> Map.new()
  end

  @spec cap([{non_neg_integer(), float()}], number(), pos_integer()) :: [
          {non_neg_integer(), float()}
        ]
  defp cap(weights, budget, limit) do
    total = Enum.sum_by(weights, &elem(&1, 1))

    {over, under} =
      Enum.split_with(weights, fn {_, weight} -> budget * weight / total > limit end)

    if over == [] or under == [] do
      Enum.map(weights, fn {global, weight} -> {global, min(budget * weight / total, limit)} end)
    else
      Enum.map(over, &{elem(&1, 0), limit * 1.0}) ++
        cap(under, budget - limit * length(over), limit)
    end
  end

  @spec part_name(layout(), pos_integer()) :: String.t()
  defp part_name(layout, part),
    do: "Part" <> String.pad_leading(Integer.to_string(part), layout.digits, "0")

  @spec context_name(layout(), context()) :: String.t()
  defp context_name(layout, context),
    do: "Synth.#{part_name(layout, context.part)}.Ctx#{context.index}"

  # The schema module of a context's resource at `position`.
  @spec schema_name(layout(), context(), non_neg_integer()) :: String.t()
  defp schema_name(layout, context, position),
    do: "#{context_name(layout, context)}.#{Enum.at(context.resources, position).schema}"

  @spec source_path(String.t()) :: Path.t()
  defp source_path(module), do: Path.join("lib", Macro.underscore(module) <> ".ex")

  @spec lines(String.t()) :: [String.t()]
  defp lines(text), do: text |> String.trim_trailing("\n") |> String.split("\n")

  @spec write!(Path.t(), Path.t(), iodata()) :: :ok
  defp write!(out, path, content) do
    path = Path.join(out, path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  # Writes one module's file and its oracle rows. The source's module is the
  # caller module of its edges.
  @spec write_source!(Path.t(), source(), File.io_device(), stats()) :: stats()
  defp write_source!(out, {module, path, lines, _before}, edges, stats) do
    write!(out, path, Enum.map(lines, &[text(&1), "\n"]))

    rows =
      for {{_text, {function, arity, callee, callee_function, callee_arity, kind}}, line} <-
            Enum.with_index(lines, 1) do
        row = [
          caller_module: module,
          caller_function: function,
          caller_arity: arity,
          callee_module: callee,
          callee_function: callee_function,
          callee_arity: callee_arity,
          kind: kind,
          path: path,
          line: line
        ]

        [encode(row), "\n"]
      end

    IO.write(edges, rows)
    count = length(lines)

    %{
      lines: stats.lines + count,
      edges: stats.edges + length(rows),
      largest: max(stats.largest, {count, module})
    }
  end

  @spec text(line()) :: String.t()
  defp text({text, _edge}), do: text
  defp text(text), do: text

  # Every module this script writes or grows, lazily, in a fixed order. A
  # generated module is read from disk; its fourth element is how many lines
  # it had, so the growth can be counted before writing.
  @spec sources(Path.t(), layout(), [plan()], %{non_neg_integer() => non_neg_integer()}) ::
          Enumerable.t(source())
  defp sources(out, layout, plans, budgets) do
    shared =
      Enum.map(shared(layout), fn {module, lines} -> {module, source_path(module), lines, 0} end)

    contexts =
      Stream.flat_map(
        plans,
        &context_sources(out, layout, &1, Map.get(budgets, &1.context.global, 0))
      )

    Stream.concat(shared, contexts)
  end

  @spec shared(layout()) :: [{String.t(), [line()]}]
  defp shared(layout) do
    graphql = Enum.filter(layout.contexts, &(:graphql in &1.extras))

    types =
      for context <- graphql,
          do:
            "  import_types SynthWeb.Schema.#{part_name(layout, context.part)}.Ctx#{context.index}Types"

    fields = fn suffix ->
      for context <- graphql,
          do: "    import_fields :#{object_prefix(layout, context)}_#{suffix}"
    end

    mutation =
      if graphql == [],
        do: [],
        else: ["", "  mutation do"] ++ fields.("mutations") ++ ["  end"]

    supervisors =
      for part <- 1..layout.parts do
        module = "Synth.#{part_name(layout, part)}.Supervisor"

        servers =
          for %{part: ^part} = context <- layout.contexts,
              :server in context.extras,
              do: "      #{context_name(layout, context)}.Server,"

        {module,
         lines("""
         defmodule #{module} do
           @moduledoc false
           use Supervisor

           def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

           @impl true
           def init(_opts) do
             children = [
         #{Enum.join(servers, "\n")}
             ]

             Supervisor.init(children, strategy: :one_for_one, max_restarts: 10)
           end
         end
         """)}
      end

    [
      {"SynthWeb.GraphQLContext",
       lines("""
       defmodule SynthWeb.GraphQLContext do
         @moduledoc "Puts the current scope into the Absinthe context."
         @behaviour Plug

         @impl true
         def init(opts), do: opts

         @impl true
         def call(conn, _opts),
           do: Absinthe.Plug.put_options(conn, context: %{current_scope: conn.assigns[:current_scope]})
       end
       """)},
      {"SynthWeb.Schema",
       [
         "defmodule SynthWeb.Schema do",
         "  use Absinthe.Schema",
         "",
         "  import_types Absinthe.Type.Custom"
       ] ++
         types ++
         ["", "  query do", "    field :version, :string, resolve: fn _, _ -> {:ok, \"1\"} end"] ++
         fields.("queries") ++ ["  end"] ++ mutation ++ ["end"]}
    ] ++
      supervisors ++
      [
        {"Synth.Worker",
         lines("""
         defmodule Synth.Worker do
           @moduledoc "A job every context implements."

           @callback name() :: String.t()
           @callback init(term()) :: {:ok, term()}
           @callback perform(term()) :: :ok | {:error, term()}
         end
         """)},
        {"Synth.Describable",
         lines("""
         defprotocol Synth.Describable do
           @spec describe(t()) :: String.t()
           def describe(value)
         end
         """)},
        {"Synth.Macros",
         lines("""
         defmodule Synth.Macros do
           @moduledoc "Injects an overridable function and a macro."

           defmacro __using__(_opts) do
             quote do
               import Synth.Macros, only: [twice: 1]

               def run(value), do: {:ran, value}

               defoverridable run: 1
             end
           end

           defmacro twice(expr) do
             quote do
               value = unquote(expr)
               {value, value}
             end
           end
         end
         """)}
      ]
  end

  @spec context_sources(Path.t(), layout(), plan(), non_neg_integer()) :: [source()]
  defp context_sources(out, layout, plan, extra) do
    context = plan.context
    ctx = context_name(layout, context)
    web = web_hosts(layout, context)
    shares = if web == [], do: @shares, else: @shares_web
    in_query = if :query in context.extras, do: trunc(extra * shares.query), else: 0
    in_web = trunc(extra * shares.web)
    in_context = extra - in_query - in_web

    generated = fn module, path ->
      original = out |> Path.join(path) |> File.read!() |> lines()
      {module, path, original, length(original)}
    end

    {_, context_path, context_lines, before} = generated.(ctx, source_path(ctx))

    [
      {ctx, context_path,
       context_lines
       |> head(["  require Logger"])
       |> grow(context_functions(plan) ++ filler(layout, context, in_context, :logic)), before}
    ] ++
      Enum.with_index(web, fn {module, path, resource}, i ->
        budget = div(in_web, length(web)) + if(i < rem(in_web, length(web)), do: 1, else: 0)
        {module, path, lines, before} = generated.(module, path)

        {module, path, grow(lines, filler(layout, context, budget, {:web, context, resource})),
         before}
      end) ++
      for kind <- context.extras, {module, lines} <- extra_modules(kind, layout, plan) do
        lines =
          if kind == :query,
            do: grow(lines, filler(layout, context, in_query, :logic)),
            else: lines

        {module, source_path(module), lines, 0}
      end
  end

  # The GraphQL object names of a context's queries and mutations.
  @spec object_prefix(layout(), context()) :: String.t()
  defp object_prefix(layout, context),
    do: "#{String.downcase(part_name(layout, context.part))}_ctx#{context.index}"

  # The generated modules of a context that hold function components: each
  # LiveView's Index and each HTML module.
  @spec web_hosts(layout(), context()) :: [{String.t(), Path.t(), resource()}]
  defp web_hosts(layout, context) do
    part = part_name(layout, context.part)
    dir = String.downcase(part)

    for resource <- context.resources, resource.kind in ["live", "html"] do
      case resource.kind do
        "live" ->
          {"SynthWeb.#{part}.#{resource.schema}Live.Index",
           "lib/synth_web/live/#{dir}/#{resource.singular}_live/index.ex", resource}

        "html" ->
          {"SynthWeb.#{part}.#{resource.schema}HTML",
           "lib/synth_web/controllers/#{dir}/#{resource.singular}_html.ex", resource}
      end
    end
  end

  # A context's summarize/1 holds three calls, one literal apply/3 and one
  # capture into other contexts, each on its own line; dispatch/2 holds its
  # one dynamic call. A context with a job enqueues it.
  @spec context_functions(plan()) :: [line()]
  defp context_functions(plan) do
    calls =
      for {target, function, arity} <- plan.calls do
        args = Enum.take(["value", "1"], arity)

        {"      #{target}.#{function}(#{Enum.join(args, ", ")}),",
         {"summarize", 1, target, function, arity, "call"}}
      end

    {apply_module, apply_function, 1} = plan.apply_target
    {capture_module, capture_function, 2} = plan.capture_target

    schedule =
      if :job in plan.context.extras do
        [
          "",
          "  def schedule_sync(scope, id),",
          "    do: __MODULE__.Jobs.Sync#{hd(plan.context.resources).schema}.enqueue(scope, id)"
        ]
      else
        []
      end

    [
      "",
      "  def dispatch(module, value) do",
      "    Logger.debug(\"dispatching to \#{inspect(module)}\")",
      "    module.list(limit: value)",
      "  end",
      "",
      "  def summarize(value) do",
      "    ["
    ] ++
      calls ++
      [
        {"      apply(#{apply_module}, :#{apply_function}, [value]),",
         {"summarize", 1, apply_module, apply_function, 1, "call"}},
        {"      &#{capture_module}.#{capture_function}/2",
         {"summarize", 1, capture_module, capture_function, 2, "capture"}},
        "    ]",
        "  end"
      ] ++ schedule
  end

  # Tags, in order, the first line holding each call with its oracle edge:
  # {caller function, caller arity, callee module, callee function, callee arity}.
  @spec calls([String.t()], [{String.t(), arity(), String.t(), String.t(), arity()}]) ::
          [line()]
  defp calls(lines, []), do: lines

  defp calls(
         [line | rest],
         [{function, arity, callee, callee_function, callee_arity} | more] = edges
       ) do
    if String.contains?(line, "#{callee}.#{callee_function}(") do
      [
        {line, {function, arity, callee, callee_function, callee_arity, "call"}}
        | calls(rest, more)
      ]
    else
      [line | calls(rest, edges)]
    end
  end

  @spec extra_modules(atom(), layout(), plan()) :: [{String.t(), [line()]}]
  defp extra_modules(:query, layout, plan) do
    module = "#{context_name(layout, plan.context)}.Query"

    [
      {module,
       lines("""
       defmodule #{module} do
         @moduledoc false
         import Ecto.Query, warn: false
         require Logger

         def page(limit) when is_integer(limit), do: Enum.to_list(1..limit//1)

         def index(items), do: Map.new(items, &{&1.id, &1})

         def names(items) do
           Logger.debug("naming \#{length(items)} items")
           items |> Enum.map(& &1.name) |> Enum.join(", ")
         end
       end
       """)}
    ]
  end

  defp extra_modules(:worker, layout, plan) do
    ctx = context_name(layout, plan.context)

    [
      {"#{ctx}.Worker",
       lines("""
       defmodule #{ctx}.Worker do
         @moduledoc false
         @behaviour Synth.Worker

         @impl true
         def name, do: "ctx#{plan.context.index}"

         @impl true
         def init(arg), do: {:ok, arg}

         @impl true
         def perform(arg) do
           _ = #{ctx}.summarize(arg)
           :ok
         end
       end
       """)}
    ]
  end

  defp extra_modules(:describable, layout, plan) do
    ctx = context_name(layout, plan.context)

    [
      {"#{ctx}.Describable",
       lines("""
       defimpl Synth.Describable, for: #{schema_name(layout, plan.context, 0)} do
         def describe(item), do: "ctx#{plan.context.index}:" <> to_string(item.name)
       end
       """)}
    ]
  end

  defp extra_modules(:hooks, layout, plan) do
    ctx = context_name(layout, plan.context)

    [
      {"#{ctx}.Hooks",
       lines("""
       defmodule #{ctx}.Hooks do
         @moduledoc false
         use Synth.Macros

         def run(value), do: value |> super() |> tag()

         def pair(value), do: twice(value + 1)

         defp tag(result), do: {:ctx#{plan.context.index}, result}
       end
       """)}
    ]
  end

  defp extra_modules(:link, layout, plan) do
    ctx = context_name(layout, plan.context)
    table = ctx |> Macro.underscore() |> String.replace("/", "_")

    [
      {"#{ctx}.Link",
       lines("""
       defmodule #{ctx}.Link do
         use Ecto.Schema
         import Ecto.Changeset

         schema "#{table}_links" do
           field :kind, :string
           belongs_to :source, #{schema_name(layout, plan.context, 0)}
           belongs_to :target, #{plan.link_target}

           timestamps(type: :utc_datetime)
         end

         def changeset(link, attrs) do
           link
           |> cast(attrs, [:kind, :source_id, :target_id])
           |> validate_required([:kind, :source_id])
         end
       end
       """)}
    ]
  end

  # An Oban job that syncs the context's first resource.
  defp extra_modules(:job, layout, plan) do
    ctx = context_name(layout, plan.context)
    %{schema: schema, singular: singular} = hd(plan.context.resources)
    module = "#{ctx}.Jobs.Sync#{schema}"

    [
      {module,
       """
       defmodule #{module} do
         @moduledoc false
         use Oban.Worker, queue: :sync, max_attempts: 5, unique: [period: 60]
         require Logger

         alias Synth.Accounts
         alias Synth.Accounts.Scope

         def enqueue(%Scope{user: user}, id), do: %{user_id: user.id, id: id} |> new() |> Oban.insert()

         @impl Oban.Worker
         def perform(%Oban.Job{args: %{"user_id" => user_id, "id" => id}, attempt: attempt}) do
           scope = user_id |> Accounts.get_user!() |> Scope.for_user()
           item = #{ctx}.get_#{singular}!(scope, id)
           Logger.info("syncing #{singular} \#{item.id}, attempt \#{attempt}")

           case #{ctx}.update_#{singular}(scope, item, %{name: String.trim(item.name)}) do
             {:ok, _item} -> :ok
             {:error, changeset} -> {:error, changeset}
           end
         end
       end
       """
       |> lines()
       |> calls([
         {"perform", 1, ctx, "get_#{singular}!", 2},
         {"perform", 1, ctx, "update_#{singular}", 3}
       ])}
    ]
  end

  # A GenServer caching the context's first resource, started by its
  # namespace's Supervisor.
  defp extra_modules(:server, layout, plan) do
    ctx = context_name(layout, plan.context)
    %{singular: singular, plural: plural} = hd(plan.context.resources)

    [
      {"#{ctx}.Server",
       """
       defmodule #{ctx}.Server do
         @moduledoc "Caches recently read #{plural}."
         use GenServer
         require Logger

         @refresh :timer.minutes(5)

         def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

         def fetch(scope, id), do: GenServer.call(__MODULE__, {:fetch, scope, id})

         def forget(id), do: GenServer.cast(__MODULE__, {:forget, id})

         @impl true
         def init(opts) do
           Process.send_after(self(), :refresh, @refresh)
           {:ok, %{items: %{}, limit: Keyword.get(opts, :limit, 1_000)}}
         end

         @impl true
         def handle_call({:fetch, scope, id}, _from, state) do
           case Map.fetch(state.items, id) do
             {:ok, item} ->
               {:reply, {:ok, item}, state}

             :error ->
               item = #{ctx}.get_#{singular}!(scope, id)
               {:reply, {:ok, item}, put_in(state.items[id], item)}
           end
         end

         @impl true
         def handle_cast({:forget, id}, state),
           do: {:noreply, update_in(state.items, &Map.delete(&1, id))}

         @impl true
         def handle_info(:refresh, state) do
           Logger.debug("refreshing \#{map_size(state.items)} cached items")
           Process.send_after(self(), :refresh, @refresh)
           {:noreply, %{state | items: %{}}}
         end
       end
       """
       |> lines()
       |> calls([{"handle_call", 3, ctx, "get_#{singular}!", 2}])}
    ]
  end

  # Absinthe types for every resource of the context, and their resolvers.
  defp extra_modules(:graphql, layout, plan) do
    context = plan.context
    ctx = context_name(layout, context)
    part = part_name(layout, context.part)
    types = "SynthWeb.Schema.#{part}.Ctx#{context.index}Types"
    resolvers = "SynthWeb.Resolvers.#{part}.Ctx#{context.index}"
    prefix = object_prefix(layout, context)
    scalar = %{"text" => "string", "utc_datetime" => "datetime"}

    objects =
      for %{singular: singular, fields: fields} <- context.resources do
        field_lines =
          for {name, type} <- [{"name", "string"} | fields] ++ [{"inserted_at", "utc_datetime"}],
              do: "    field :#{name}, :#{Map.get(scalar, type, type)}\n"

        """

          object :#{singular} do
            field :id, non_null(:id)
        #{field_lines}  end
        """
      end

    queries =
      for %{singular: singular, plural: plural} <- context.resources do
        """

            field :#{plural}, list_of(:#{singular}) do
              resolve &Resolvers.list_#{plural}/3
            end

            field :#{singular}, :#{singular} do
              arg :id, non_null(:id)
              resolve &Resolvers.get_#{singular}/3
            end
        """
      end

    mutations =
      for %{singular: singular} <- context.resources do
        """

            field :update_#{singular}, :#{singular} do
              arg :id, non_null(:id)
              arg :name, :string
              resolve &Resolvers.update_#{singular}/3
            end
        """
      end

    functions =
      for %{singular: singular, plural: plural} <- context.resources do
        """

          def list_#{plural}(_parent, _args, %{context: %{current_scope: scope}}),
            do: {:ok, #{ctx}.list_#{plural}(scope)}

          def get_#{singular}(_parent, %{id: id}, %{context: %{current_scope: scope}}),
            do: {:ok, #{ctx}.get_#{singular}!(scope, id)}

          def update_#{singular}(_parent, %{id: id} = args, %{context: %{current_scope: scope}}) do
            item = #{ctx}.get_#{singular}!(scope, id)

            case #{ctx}.update_#{singular}(scope, item, Map.delete(args, :id)) do
              {:ok, item} -> {:ok, item}
              {:error, changeset} -> {:error, message: "invalid #{singular}", details: inspect(changeset.errors)}
            end
          end
        """
      end

    edges =
      Enum.flat_map(context.resources, fn %{singular: singular, plural: plural} ->
        [
          {"list_#{plural}", 3, ctx, "list_#{plural}", 1},
          {"get_#{singular}", 3, ctx, "get_#{singular}!", 2},
          {"update_#{singular}", 3, ctx, "get_#{singular}!", 2},
          {"update_#{singular}", 3, ctx, "update_#{singular}", 3}
        ]
      end)

    [
      {types,
       lines("""
       defmodule #{types} do
         @moduledoc false
         use Absinthe.Schema.Notation

         alias #{resolvers}, as: Resolvers
       #{objects}
         object :#{prefix}_queries do\
       #{queries}  end

         object :#{prefix}_mutations do\
       #{mutations}  end
       end
       """)},
      {resolvers,
       """
       defmodule #{resolvers} do
         @moduledoc false
       #{functions}end
       """
       |> lines()
       |> calls(edges)}
    ]
  end

  # Inserts lines after the module's `defmodule` line.
  @spec head([line()], [line()]) :: [line()]
  defp head([first | rest], extra), do: [first | extra] ++ rest

  # Inserts extra lines before the module's closing `end`.
  @spec grow([line()], [line()]) :: [line()]
  defp grow(lines, []), do: lines
  defp grow(lines, extra), do: List.delete_at(lines, -1) ++ extra ++ ["end"]

  # Exactly `budget` lines of extra functions (numbered, so names never
  # clash), padded with comment lines when the next one doesn't fit. The
  # templates mimic what a team adds to a Phoenix app: Ecto queries and
  # changesets, `with` pipelines, logging, small helpers in context and query
  # modules (`:logic`); function components in LiveViews and HTML modules
  # (`:web`). In `:logic` hosts a fifth of them call another context
  # (recorded in the oracle).
  @spec filler(layout(), context(), non_neg_integer(), host()) :: [line()]
  defp filler(_layout, _context, 0, _host), do: []
  defp filler(layout, context, budget, host), do: filler(layout, context, budget, host, 1, [])

  @spec filler(layout(), context(), non_neg_integer(), host(), pos_integer(), [[line()]]) ::
          [line()]
  defp filler(layout, context, budget, host, n, acc) do
    function = extra_function(layout, context, n, host)

    if length(function) <= budget do
      filler(layout, context, budget - length(function), host, n + 1, [function | acc])
    else
      Enum.concat(Enum.reverse(acc)) ++ List.duplicate("  # Reserved.", budget)
    end
  end

  @spec extra_function(layout(), context(), pos_integer(), host()) :: [line()]
  defp extra_function(layout, context, n, :logic) do
    position = :rand.uniform(length(context.resources)) - 1
    resource = Enum.at(context.resources, position)
    schema = schema_name(layout, context, position)
    [{field, _} | _] = resource.fields
    k = :rand.uniform(97)

    case :rand.uniform(10) do
      r when r <= 2 ->
        {target, function, arity} = target(layout, context, :any)
        args = Enum.join(Enum.take(["scope", "id"], arity), ", ")

        [
          "",
          "  def op_#{n}(scope, value) do",
          "    case value do",
          "      nil ->",
          "        Logger.warning(\"op_#{n}: missing value\")",
          "        {:error, :missing}",
          "",
          "      %{id: id} ->",
          {"        {:ok, id, #{target}.#{function}(#{args})}",
           {"op_#{n}", 2, target, function, arity, "call"}},
          "",
          "      other ->",
          "        unexpected_#{n}(other)",
          "    end",
          "  end",
          "",
          "  defp unexpected_#{n}(other), do: {:error, \"op_#{n}: unexpected \#{inspect(other)}\"}"
        ]

      r when r <= 4 ->
        [
          "",
          "  def op_#{n}(%{user: %{id: user_id}}, opts \\\\ []) do",
          "    limit = Keyword.get(opts, :limit, #{k})",
          "",
          "    user_id",
          "    |> query_#{n}(limit, Keyword.get(opts, :offset, 0))",
          "    |> Synth.Repo.all()",
          "  end",
          "",
          "  defp query_#{n}(user_id, limit, offset) do",
          "    Ecto.Query.from(i in #{schema},",
          "      where: i.user_id == ^user_id and not is_nil(i.name),",
          "      order_by: [desc: i.inserted_at, asc: i.name],",
          "      limit: ^limit,",
          "      offset: ^offset,",
          "      select: %{id: i.id, name: i.name, #{field}: i.#{field}}",
          "    )",
          "  end"
        ]

      5 ->
        numbers = for {name, type} <- resource.fields, type in ["integer", "decimal"], do: name
        cast = [:name | Enum.map(resource.fields, &String.to_atom(elem(&1, 0)))]

        [
          "",
          "  def op_#{n}(%#{schema}{} = item, attrs) do",
          "    item",
          "    |> Ecto.Changeset.cast(attrs, #{inspect(cast)})",
          "    |> Ecto.Changeset.validate_required([:name])",
          "    |> Ecto.Changeset.validate_length(:name, min: 1, max: #{k + 20})"
        ] ++
          Enum.map(
            numbers,
            &"    |> Ecto.Changeset.validate_number(:#{&1}, greater_than_or_equal_to: 0)"
          ) ++
          [
            "    |> Ecto.Changeset.update_change(:name, &trim_#{n}/1)",
            "  end",
            "",
            "  defp trim_#{n}(value) when is_binary(value), do: String.trim(value)",
            "  defp trim_#{n}(value), do: value"
          ]

      6 ->
        [
          "",
          "  def op_#{n}(%{id: id, name: name} = item, opts \\\\ []) do",
          "    prefix = Keyword.get(opts, :prefix, \"ctx#{context.index}\")",
          "    label = \"\#{prefix}-\#{id}: \#{String.upcase(to_string(name))}\"",
          "    Localize.put_locale(Keyword.get(opts, :locale, :en))",
          "    count = Localize.Number.to_string!(Keyword.get(opts, :count, #{k}))",
          "    Logger.debug(\"op_#{n} counted \#{count}\")",
          "    Logger.info(\"op_#{n} \#{label}\", item_id: id)",
          "",
          "    item",
          "    |> Map.put(:label, label)",
          "    |> Map.update(:#{field}, #{k}, &{&1, #{k}})",
          "    |> Map.take([:id, :label, :#{field}])",
          "  end"
        ]

      r when r <= 8 ->
        [
          "",
          "  def name_#{n}(%{name: name}), do: name |> to_string() |> String.trim()",
          "",
          "  def label_#{n}(item), do: \"\#{name_#{n}(item)} \#{inspect(key_#{n}(item))}\"",
          "",
          "  defp key_#{n}(item), do: {:ctx#{context.index}, item.id, Map.get(item, :#{field})}"
        ]

      9 ->
        [
          "",
          "  def params_#{n}(params) when is_map(params) do",
          "    params",
          "    |> Map.take([\"name\", \"#{field}\"])",
          "    |> Map.new(fn {key, value} -> {key, normalize_#{n}(value)} end)",
          "    |> Map.put_new(\"#{field}\", #{k})",
          "  end",
          "",
          "  defp normalize_#{n}(value) when is_binary(value), do: value |> String.trim() |> String.downcase()",
          "  defp normalize_#{n}(value), do: value"
        ]

      10 ->
        [
          "",
          "  def run_#{n}(scope, id, attrs) do",
          "    with {:ok, item} <- fetch_#{n}(scope, id),",
          "         {:ok, item} <- merge_#{n}(item, attrs) do",
          "      Logger.debug(\"run_#{n} updated \#{item.id}\")",
          "      {:ok, item}",
          "    end",
          "  end",
          "",
          "  defp fetch_#{n}(%{user: %{id: user_id}}, id) do",
          "    case Synth.Repo.get_by(#{schema}, id: id, user_id: user_id) do",
          "      nil -> {:error, :not_found}",
          "      item -> {:ok, item}",
          "    end",
          "  end",
          "",
          "  defp merge_#{n}(item, attrs), do: {:ok, Map.merge(item, Map.take(attrs, [:name, :#{field}]))}"
        ]
    end
  end

  defp extra_function(layout, _context, n, {:web, context, resource}) do
    path = "/#{String.downcase(part_name(layout, context.part))}/#{resource.plural}"
    [{field, _} | _] = resource.fields
    k = :rand.uniform(97)

    case :rand.uniform(5) do
      r when r <= 2 ->
        [
          "",
          "  attr :item, :map, required: true",
          "  attr :count, :integer, default: 0",
          "  attr :tags, :list, default: []",
          "",
          "  def card_#{n}(assigns) do",
          "    ~H\"\"\"",
          "    <div id={\"card-#{n}-\#{@item.id}\"} class={[\"item\", @item.#{field} && \"filled\"]}>",
          "      <.link navigate={~p\"#{path}/\#{@item}\"}>",
          "        {@item.name}",
          "      </.link>",
          "      <span :if={@count > #{k}}>{ngettext(\"1 item\", \"%{count} items\", @count)}</span>",
          "      <ul>",
          "        <li :for={tag <- @tags} class=\"tag\">{tag}</li>",
          "      </ul>",
          "    </div>",
          "    \"\"\"",
          "  end"
        ]

      3 ->
        [
          "",
          "  def row_#{n}(assigns) do",
          "    ~H\"\"\"",
          "    <tr id={\"row-#{n}-\#{@item.id}\"}>",
          "      <td>{@item.name}</td>",
          "      <td>{format_#{n}(@item.#{field})}</td>",
          "      <td><.link navigate={~p\"#{path}/\#{@item}/edit\"}>Edit</.link></td>",
          "    </tr>",
          "    \"\"\"",
          "  end",
          "",
          "  defp format_#{n}(nil), do: \"-\"",
          "  defp format_#{n}(%Decimal{} = value), do: Localize.Number.to_string!(value)",
          "  defp format_#{n}(%Date{} = value), do: Localize.Date.to_string!(value, format: :medium)",
          "  defp format_#{n}(value), do: to_string(value)"
        ]

      _ ->
        [
          "",
          "  def summary_#{n}(items) when is_list(items) do",
          "    filled = Enum.count(items, & &1.#{field})",
          "    names = items |> Enum.map(&to_string(&1.name)) |> Enum.sort() |> Localize.List.to_string!()",
          "    gettext(\"%{count} items, %{filled} with #{field} (#{k}): %{names}\",",
          "      count: length(items),",
          "      filled: filled,",
          "      names: names",
          "    )",
          "  end"
        ]
    end
  end
end

Synth.Gen.main(System.argv())
