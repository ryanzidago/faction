defmodule Faction.Beam do
  @moduledoc """
  Reads the Elixir debug info and export table of a BEAM file without loading it.
  """

  @enforce_keys [:module, :file, :compile_dir, :line, :definitions, :exports, :behaviours]
  defstruct [:module, :file, :compile_dir, :line, :definitions, :exports, :behaviours]

  @typedoc "A definition as recorded by the Elixir compiler."
  @type definition() ::
          {{atom(), arity()}, :def | :defp | :defmacro | :defmacrop, keyword(), list(tuple())}

  @type t() :: %__MODULE__{
          module: module(),
          file: Path.t(),
          compile_dir: Path.t(),
          line: pos_integer(),
          definitions: list(definition()),
          exports: list({atom(), arity()}),
          behaviours: list(module())
        }

  @doc "Reads a BEAM file. Fails for BEAMs without Elixir debug info."
  @spec read(path :: Path.t()) :: {:ok, t()} | {:error, String.t()}
  def read(path) do
    with {:ok, binary} <- read_file(path) do
      chunks(binary)
    end
  end

  @spec read_file(path :: Path.t()) :: {:ok, binary()} | {:error, String.t()}
  defp read_file(path) do
    case Faction.RawFile.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @spec chunks(binary :: binary()) :: {:ok, t()} | {:error, String.t()}
  defp chunks(binary) do
    case :beam_lib.chunks(binary, [:debug_info, :exports, :attributes]) do
      {:ok,
       {module,
        [
          debug_info: {:debug_info_v1, :elixir_erl, {:elixir_v1, info, _specs}},
          exports: exports,
          attributes: attributes
        ]}} ->
        {:ok,
         %__MODULE__{
           module: module,
           file: info.file,
           compile_dir: compile_dir(info.file, info.relative_file),
           line: anno_line(info.anno),
           definitions: info.definitions,
           exports: exports,
           behaviours:
             Enum.uniq(
               Keyword.get(attributes, :behaviour, []) ++ Keyword.get(attributes, :behavior, [])
             )
         }}

      {:ok, {_module, [debug_info: _other, exports: _exports, attributes: _attributes]}} ->
        {:error, "no Elixir debug info"}

      {:error, :beam_lib, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc "The name of a module as written in source: MyApp.Orders for Elixir, my_mod for Erlang."
  @spec module_name(module :: module()) :: String.t()
  def module_name(module) do
    case Atom.to_string(module) do
      "Elixir." <> name -> name
      name -> name
    end
  end

  @doc "The compiled name and arity of a definition: defmacro foo(a) compiles to MACRO-foo/2."
  @spec compiled_name(kind :: atom(), name :: atom(), arity :: arity()) :: {String.t(), arity()}
  def compiled_name(kind, name, arity) when kind in [:defmacro, :defmacrop],
    do: {"MACRO-#{name}", arity + 1}

  def compiled_name(_kind, name, arity), do: {Atom.to_string(name), arity}

  # The directory the compiler ran in; relative paths in the debug info, such
  # as the files of `quote location: :keep` code, are relative to it.
  @spec compile_dir(file :: Path.t(), relative_file :: Path.t()) :: Path.t()
  defp compile_dir(file, relative_file) do
    if Path.type(relative_file) == :relative and String.ends_with?(file, "/" <> relative_file) do
      String.trim_trailing(file, "/" <> relative_file)
    else
      Path.dirname(file)
    end
  end

  @spec anno_line(anno :: :erl_anno.anno()) :: pos_integer()
  defp anno_line(anno), do: :erl_anno.line(anno)
end
