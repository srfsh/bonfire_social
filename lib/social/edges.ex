defmodule Bonfire.Social.Edges do
  use Arrows
  use Bonfire.Common.Utils
  use Bonfire.Repo
  import Bonfire.Boundaries.Queries
  import Where
  alias Bonfire.Data.Edges.Edge
  alias Bonfire.Social.Objects
  alias Pointers.ULID

  def changeset(schema, subject, verb, object, preset_or_custom_boundary) when is_atom(schema), do: changeset({schema, schema}, subject, verb, object, preset_or_custom_boundary)
  def changeset({insert_schema, type_schema}, subject, verb, object, preset_or_custom_boundary) do
    id = ULID.generate()
    %{id: id,
      edge: %{
        id: id,
        subject_id: ulid(subject),
        object_id:  ulid(object),
        table_id:   type_schema.__pointers__(:table_id),
      }}
    |> Changeset.cast(struct(insert_schema), ..., [:id])
    |> Changeset.cast_assoc(:edge, [:required, with: &Edge.changeset/2])
    |> Objects.cast_basic(%{verb: verb}, subject, preset_or_custom_boundary)
    # |> Changeset.cast_assoc(:controlled)
  end

  def get(type, subject, object, opts \\ [])

  def get(type, filters, opts, []) when is_list(filters) and is_list(opts) do
    do_query(type, filters, opts)
    |> dump
    |> repo().single()
  end

  def get(type, subject, object, opts) do
    do_query(type, subject, object, opts)
    |> repo().single()
  end

  def get!(type, subject, objects, opts \\ [])
  def get!(type, subject, [], opts) do
    []
  end
  def get!(type, subject, objects, opts) when is_list(objects) do
    do_query(type, subject, objects, opts)
    |> repo().all()
  end
  def get!(type, subject, object, opts) do
    do_query(type, subject, object, opts)
    |> repo().one()
  end

  # defp do_query(type, subject, object, opts \\ [])

  defp do_query(type_context, filters, opts) when is_list(filters) and is_list(opts) do
    filters
    |> type_context.query(opts)
    # |> debug()
  end

  defp do_query({type_context, type}, subject, object, opts) do
    [subject: subject, object: object]
    |> type_context.query(type, Keyword.put_new(opts, :current_user, subject))
    # |> debug()
  end

  defp do_query(type_context, subject, object, opts) do
    [subject: subject, object: object]
    |> type_context.query(Keyword.put_new(opts, :current_user, subject))
    # |> debug()
  end

  def query(filters, opts) do
    from(root in Edge, as: :edge)
    |> boundarise(root.id, opts)
    |> filter(filters, opts)
  end

  def query_parent(query_schema, filters, opts) do
    # debug(opts)
    from(root in query_schema, as: :root)
    |> proload(:edge)
    |> boundarise(root.id, opts)
    |> filter(filters, opts)
    |> maybe_proload(!is_list(opts) || opts[:preload])
  end

  defp maybe_proload(query, _skip_preload? = false), do: query

  defp maybe_proload(query, :subject) do
    query
    |> proload([edge: [
      subject: {"subject_", [:profile, :character]}
      ]])
  end

  defp maybe_proload(query, :object) do
    query
    |> proload([edge: [
      object: {"object_", [:profile, :character]}
      ]])
  end

  defp maybe_proload(query, _) do
    query
    |> maybe_proload(:object)
    |> maybe_proload(:subject)
  end

  defp filter(query, filters, opts) when is_list(filters),
    do: Enum.reduce(filters, query, &filter(&2, &1, opts))
        |> query_filter(Keyword.drop(filters, [:object, :subject, :type]))

  defp filter(query, {:subject, subject}, opts) do
    case subject do
      :visible -> boundarise(query, edge.subject_id, opts)
      _ when is_list(subject) ->
        where(query, [edge: edge], edge.subject_id in ^ulid(subject))
      _ when is_map(subject) or is_binary(subject) ->
        where(query, [edge: edge], edge.subject_id == ^ulid(subject))
    end
  end

  defp filter(query, {:object, object}, opts) do
    case object do
      :visible -> boundarise(query, edge.object_id, opts)
      _ when is_list(object) ->
        where(query, [edge: edge], edge.object_id in ^ulid(object))
      _ when is_map(object) or is_binary(object) ->
        where(query, [edge: edge], edge.object_id == ^ulid(object))
    end
  end

  defp filter(query, {:type, type}, opts) do
    case type do
      _ when is_list(type) ->
        where(query, [edge: edge], edge.table_id in ^ulid(type))
      _ when is_map(type) or is_binary(type) ->
        where(query, [edge: edge], edge.table_id == ^ulid(type))
    end
  end

  defp filter(query, filters, _opts) do
    query
  end

  #doc "Delete Follows where i am the subject"
  def delete_by_subject(user), do: query([subject: user], skip_boundary_check: true) |> do_delete()

  #doc "Delete Follows where i am the object"
  def delete_by_object(user), do: query([object: user], skip_boundary_check: true) |> do_delete()

  #doc "Delete Follows where i am the subject or the object."
  # defp delete_by_any(me), do: do_delete(by_any_q(me))

  #doc "Delete Follows where i am the subject and someone else is the object."
  def delete_by_both(me, schema, object), do: [subject: me, object: object, table_id: schema.__pointers__(:table_id)] |> query(skip_boundary_check: true) |> do_delete()

  defp do_delete(q), do: q |> Ecto.Query.exclude(:preload) |> Ecto.Query.exclude(:order_by) |> repo().delete_all() |> elem(1)

end
