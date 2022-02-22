defmodule Bonfire.Social.Acts.Boundaries do

  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Me.Acls
  alias Ecto.Changeset
  require Act
  use Arrows

  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    changeset = epic.assigns[on]
    current_user = epic.assigns.options[:current_user]
    cond do
      epic.errors != [] ->
        Act.debug(epic, act, length(epic.errors), "Skipping due to epic errors")
        epic
      is_nil(on) or not is_atom(on) ->
        Act.debug(epic, act, on, "Skipping due to `on` option")
        epic
      not (is_struct(current_user) or is_binary(current_user)) ->
        Act.warn(current_user, "Skipping due to current_user")
        epic
      not is_struct(changeset) || changeset.__struct__ != Changeset ->
        Act.debug(epic, act, changeset, "Skipping :#{on} due to changeset")
        epic
      changeset.action not in [:insert, :delete] ->
        Act.debug(epic, act, changeset.action, "Skipping, no matching action on changeset")
        epic
      changeset.action == :insert ->
        boundary = epic.assigns.options[:boundary]
        Act.debug(epic, act, "Casting boundaries")
        changeset
        |> Acls.cast(current_user, boundary)
        |> Epic.assign(epic, on, ...)
      changeset.action == :delete ->
        # TODO: deletion
        epic
    end
  end

end
