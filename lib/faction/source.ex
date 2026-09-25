defmodule Faction.Source do
  @moduledoc """
  Line ranges of module and function definitions, read from a source file.

  The compiler records where definitions start but not where they end, so the
  end lines come from parsing the source. Nothing else is taken from source.
  """

  @enforce_keys [:modules, :definitions, :definition_lines, :tests]
  defstruct [:modules, :definitions, :definition_lines, :tests]

  @typedoc "A source position: {line, column}."
  @type position() :: {pos_integer(), pos_integer()}

  @typedoc """
  End lines. `modules` is keyed by the line of a `defmodule`, `defimpl` or
  `defprotocol` (the compiler records only the line for some of them);
  `definitions` by the position of the function name in a `def`, `defp`,
  `defmacro` or `defmacrop` head, which is where the compiler anchors each
  clause. `definition_lines` holds the same end lines keyed by the head's
  line only, for clauses the compiler records without a column. `tests` is
  keyed by the line of an ExUnit `test` with a `do` block, where the compiler
  anchors the test function.
  """
  @type t() :: %__MODULE__{
          modules: %{pos_integer() => pos_integer()},
          definitions: %{position() => pos_integer()},
          definition_lines: %{pos_integer() => pos_integer()},
          tests: %{pos_integer() => pos_integer()}
        }

  @module_keywords [:defmodule, :defimpl, :defprotocol]
  @definition_keywords [:def, :defp, :defmacro, :defmacrop]

  @doc "Parses a source file. Fails when it cannot be read or parsed."
  @spec read(path :: Path.t()) :: {:ok, t()} | :error
  def read(path) do
    with {:ok, contents} <- Faction.RawFile.read(path),
         {:ok, ast} <-
           Code.string_to_quoted(contents, token_metadata: true, columns: true, file: path) do
      {:ok, parse(ast)}
    else
      _error -> :error
    end
  end

  @doc "The end line of the module declared on `line`, or nil when no module is declared there."
  @spec module_end_line(source :: t(), line :: pos_integer()) :: pos_integer() | nil
  def module_end_line(%__MODULE__{} = source, line), do: Map.get(source.modules, line)

  @doc """
  The end line of the definition whose head is at `position`, or nil when no
  definition starts there. A position without a column (code generated with
  `quote line: line`, such as Phoenix's function component wrappers) matches
  a definition starting on that line.
  """
  @spec definition_end_line(source :: t(), position :: {pos_integer(), pos_integer() | nil}) ::
          pos_integer() | nil
  def definition_end_line(%__MODULE__{} = source, {line, nil}),
    do: Map.get(source.definition_lines, line)

  def definition_end_line(%__MODULE__{} = source, position),
    do: Map.get(source.definitions, position)

  @doc "The end line of the `test` block starting on `line`, or nil when none starts there."
  @spec test_end_line(source :: t(), line :: pos_integer()) :: pos_integer() | nil
  def test_end_line(%__MODULE__{} = source, line), do: Map.get(source.tests, line)

  @spec parse(ast :: Macro.t()) :: t()
  defp parse(ast) do
    {_ast, source} =
      Macro.prewalk(
        ast,
        %__MODULE__{modules: %{}, definitions: %{}, definition_lines: %{}, tests: %{}},
        fn
          {keyword, meta, [_ | _]} = node, source when keyword in @module_keywords ->
            {node, put_module(source, meta[:line], node)}

          {keyword, _meta, [head | _]} = node, source when keyword in @definition_keywords ->
            {node, put_definition(source, head_position(head), node)}

          {:test, meta, [_name | _] = args} = node, source ->
            {node, put_test(source, meta[:line], List.last(args), node)}

          node, source ->
            {node, source}
        end
      )

    source
  end

  @spec put_definition(source :: t(), position :: position() | nil, node :: Macro.t()) :: t()
  defp put_definition(source, nil, _node), do: source

  defp put_definition(source, {line, _column} = position, node) do
    end_line = last_line(node)

    %{
      source
      | definitions: Map.put(source.definitions, position, end_line),
        definition_lines: Map.update(source.definition_lines, line, end_line, &max(&1, end_line))
    }
  end

  # Only a test with a body defines a range; `test "pending"` is one line.
  @spec put_test(
          source :: t(),
          line :: pos_integer() | nil,
          last_arg :: Macro.t(),
          node :: Macro.t()
        ) :: t()
  defp put_test(source, line, [{:do, _body} | _], node) when is_integer(line),
    do: %{source | tests: Map.put(source.tests, line, last_line(node))}

  defp put_test(source, _line, _last_arg, _node), do: source

  @spec put_module(source :: t(), line :: pos_integer() | nil, node :: Macro.t()) :: t()
  defp put_module(source, nil, _node), do: source

  defp put_module(source, line, node),
    do: %{source | modules: Map.put(source.modules, line, last_line(node))}

  @spec head_position(head :: Macro.t()) :: position() | nil
  defp head_position({:when, _meta, [call | _guards]}), do: head_position(call)
  defp head_position({_name, meta, _args}) when is_list(meta), do: position(meta)
  defp head_position(_head), do: nil

  @spec position(meta :: keyword()) :: position() | nil
  defp position(meta) do
    case {meta[:line], meta[:column]} do
      {line, column} when is_integer(line) and is_integer(column) -> {line, column}
      _missing -> nil
    end
  end

  @spec last_line(node :: Macro.t()) :: pos_integer()
  defp last_line(node) do
    {_node, max} =
      Macro.prewalk(node, 0, fn
        {_form, meta, _args} = node, max when is_list(meta) ->
          {node, max(max, meta_last_line(meta))}

        node, max ->
          {node, max}
      end)

    max
  end

  @spec meta_last_line(meta :: keyword()) :: non_neg_integer()
  defp meta_last_line(meta) do
    [meta, meta[:end], meta[:closing], meta[:end_of_expression]]
    |> Enum.map(&line_of/1)
    |> Enum.max()
  end

  @spec line_of(meta :: keyword() | nil) :: non_neg_integer()
  defp line_of(meta) when is_list(meta) do
    case meta[:line] do
      line when is_integer(line) -> line
      _missing -> 0
    end
  end

  defp line_of(nil), do: 0
end
