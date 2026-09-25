defmodule Faction.Ecto do
  @moduledoc """
  Ecto schemas, fields and associations, read from the literal clauses of
  `__schema__/1` and `__schema__/2` in a module's debug info.

  Nothing is loaded or evaluated: clause bodies are decoded only when they are
  literals (see `Faction.Literal`).
  """

  alias Faction.Beam
  alias Faction.Literal

  @typedoc "Rows keyed by relation name."
  @type rows() :: %{ecto_schemas: list(map()), ecto_fields: list(map()), ecto_assocs: list(map())}

  @doc "The Ecto rows of a module; all empty unless it defines an Ecto schema."
  @spec rows(beam :: Beam.t()) :: rows()
  def rows(beam) do
    case schema_clauses(beam.definitions) do
      %{source: _source} = clauses -> schema_rows(Beam.module_name(beam.module), clauses)
      _not_a_schema -> %{ecto_schemas: [], ecto_fields: [], ecto_assocs: []}
    end
  end

  # Literal-argument clauses of __schema__/1 keyed by their argument, and of
  # __schema__/2 keyed by {first, second}. Bodies stay as AST until decoded.
  @spec schema_clauses(definitions :: list(Beam.definition())) :: %{term() => Macro.t()}
  defp schema_clauses(definitions) do
    for {{:__schema__, arity}, :def, _meta, clauses} <- definitions,
        arity in [1, 2],
        {_meta, args, [], body} <- clauses,
        key = clause_key(args),
        into: %{},
        do: {key, body}
  end

  @spec clause_key(args :: list(Macro.t())) :: term() | nil
  defp clause_key([key]) when is_atom(key), do: key
  defp clause_key([key, name]) when is_atom(key) and is_atom(name), do: {key, name}
  defp clause_key(_args), do: nil

  @spec schema_rows(module :: String.t(), clauses :: %{term() => Macro.t()}) :: rows()
  defp schema_rows(module, clauses) do
    primary_key = decode(clauses, :primary_key, [])

    fields =
      for field <- decode(clauses, :fields, []) do
        %{
          module: module,
          field: Atom.to_string(field),
          type: type_name(decode(clauses, {:type, field}, nil)),
          is_primary_key: field in primary_key
        }
      end

    associations =
      for name <- decode(clauses, :associations, []),
          association = decode(clauses, {:association, name}, nil),
          is_map(association) do
        assoc_row(module, name, association)
      end

    embeds =
      for name <- decode(clauses, :embeds, []),
          embed = decode(clauses, {:embed, name}, nil),
          is_map(embed) do
        assoc_row(module, name, embed)
      end

    %{
      ecto_schemas: [%{module: module, source_table: decode(clauses, :source, nil)}],
      ecto_fields: fields,
      ecto_assocs: associations ++ embeds
    }
  end

  @spec assoc_row(module :: String.t(), name :: atom(), struct :: map()) :: map()
  defp assoc_row(module, name, struct) do
    related = Map.get(struct, :related)

    %{
      module: module,
      name: Atom.to_string(name),
      kind: assoc_kind(Map.get(struct, :__struct__), Map.get(struct, :cardinality)),
      related_module: related_module(related)
    }
  end

  @spec related_module(related :: term()) :: String.t() | nil
  defp related_module(related) when is_atom(related) and not is_nil(related),
    do: Beam.module_name(related)

  defp related_module(_related), do: nil

  @spec assoc_kind(struct :: module() | nil, cardinality :: :one | :many | nil) :: String.t()
  defp assoc_kind(Ecto.Association.BelongsTo, _cardinality), do: "belongs_to"
  defp assoc_kind(Ecto.Association.Has, :one), do: "has_one"
  defp assoc_kind(Ecto.Association.Has, :many), do: "has_many"
  defp assoc_kind(Ecto.Association.HasThrough, :one), do: "has_one_through"
  defp assoc_kind(Ecto.Association.HasThrough, :many), do: "has_many_through"
  defp assoc_kind(Ecto.Association.ManyToMany, _cardinality), do: "many_to_many"
  defp assoc_kind(Ecto.Embedded, :one), do: "embeds_one"
  defp assoc_kind(Ecto.Embedded, :many), do: "embeds_many"
  defp assoc_kind(struct, _cardinality), do: Beam.module_name(struct || :unknown)

  # Types as written in a schema: :decimal is "decimal", a custom or
  # parameterized type is its module ("Ecto.Enum"), composites keep their
  # shape ("{:array, :string}").
  @spec type_name(type :: term()) :: String.t() | nil
  defp type_name(nil), do: nil
  defp type_name(type) when is_atom(type), do: Beam.module_name(type)
  defp type_name(type), do: inspect(simplify_type(type))

  @spec simplify_type(type :: term()) :: term()
  defp simplify_type({:parameterized, {module, _params}}) when is_atom(module), do: module
  defp simplify_type({:parameterized, module, _params}) when is_atom(module), do: module

  defp simplify_type({composite, inner}) when is_atom(composite),
    do: {composite, simplify_type(inner)}

  defp simplify_type(type), do: type

  @spec decode(clauses :: %{term() => Macro.t()}, key :: term(), default :: term()) :: term()
  defp decode(clauses, key, default) do
    case Map.fetch(clauses, key) do
      {:ok, ast} ->
        case Literal.literal(ast) do
          {:ok, value} -> value
          :error -> default
        end

      :error ->
        default
    end
  end
end
