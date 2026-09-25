defmodule Faction.Behaviours do
  @moduledoc """
  Callback contracts of behaviours, read from the behaviour's BEAM.

  The callbacks come from the literals `behaviour_info/1` returns, read by
  disassembling the BEAM without loading it. This works for Elixir and Erlang
  behaviours alike, with or without debug info. Macro callbacks keep their
  compiled name and arity, e.g. MACRO-template/2.
  """

  alias Faction.Beam

  @doc """
  Reads the BEAM of `behaviour`: first from `ebin_dirs` (application, then
  dependencies), then from the Elixir and Erlang/OTP installation Faction runs
  on, including when those are packed inside the Faction escript. Nothing is
  loaded.
  """
  @spec read(behaviour :: module(), ebin_dirs :: list(Path.t())) :: {:ok, binary()} | :error
  def read(behaviour, ebin_dirs) do
    file = Atom.to_string(behaviour) <> ".beam"

    found =
      Enum.find_value(ebin_dirs, fn dir ->
        case Faction.RawFile.read(Path.join(dir, file)) do
          {:ok, binary} -> binary
          {:error, _reason} -> nil
        end
      end)

    if found do
      {:ok, found}
    else
      installed(behaviour)
    end
  end

  @spec installed(behaviour :: module()) :: {:ok, binary()} | :error
  defp installed(behaviour) do
    case :code.get_object_code(behaviour) do
      {^behaviour, binary, _file} -> {:ok, binary}
      :error -> :error
    end
  end

  @doc "The `callbacks` rows of a behaviour from its BEAM, sorted by function and arity."
  @spec callback_rows(behaviour :: module(), beam :: binary()) ::
          {:ok, list(map())} | {:error, String.t()}
  def callback_rows(behaviour, beam) do
    with {:ok, functions} <- disassemble(beam),
         {:ok, info} <- behaviour_info(functions) do
      optional = MapSet.new(Map.get(info, :optional_callbacks, []))

      rows =
        info
        |> Map.get(:callbacks, [])
        |> Enum.sort()
        |> Enum.map(fn {function, arity} ->
          %{
            behaviour: Beam.module_name(behaviour),
            function: Atom.to_string(function),
            arity: arity,
            is_optional: MapSet.member?(optional, {function, arity})
          }
        end)

      {:ok, rows}
    end
  end

  @spec disassemble(beam :: binary()) :: {:ok, list(tuple())} | {:error, String.t()}
  defp disassemble(beam) do
    case :beam_disasm.file(beam) do
      {:beam_file, _module, _exports, _attributes, _compile_info, functions} -> {:ok, functions}
      {:error, :beam_lib, reason} -> {:error, inspect(reason)}
    end
  end

  # behaviour_info/1 compiles to a select on its argument, jumping to labels
  # that each move a literal list (or nil, the empty list) into the return register.
  @spec behaviour_info(functions :: list(tuple())) ::
          {:ok, %{atom() => list({atom(), arity()})}} | {:error, String.t()}
  defp behaviour_info(functions) do
    case Enum.find(functions, &match?({:function, :behaviour_info, 1, _entry, _code}, &1)) do
      {:function, :behaviour_info, 1, _entry, code} ->
        labels = Enum.flat_map(code, &select_labels/1)

        {:ok,
         Map.new(labels, fn {key, label} ->
           {key, returned_literal(code, label)}
         end)}

      nil ->
        {:error, "no behaviour_info/1"}
    end
  end

  @spec select_labels(instruction :: term()) :: list({atom(), non_neg_integer()})
  defp select_labels({:select_val, {:x, 0}, _fail, {:list, list}}) do
    list
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [{:atom, key}, {:f, label}] -> [{key, label}]
      _other -> []
    end)
  end

  defp select_labels(_instruction), do: []

  @spec returned_literal(code :: list(term()), label :: non_neg_integer()) ::
          list({atom(), arity()})
  defp returned_literal(code, label) do
    code
    |> Enum.drop_while(&(&1 != {:label, label}))
    |> Enum.find_value([], fn
      {:move, {:literal, list}, {:x, 0}} when is_list(list) -> list
      {:move, nil, {:x, 0}} -> []
      _other -> nil
    end)
  end
end
