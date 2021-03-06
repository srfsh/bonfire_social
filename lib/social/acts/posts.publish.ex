defmodule Bonfire.Social.Acts.Posts.Publish do
  @moduledoc """
  Creates a changeset for publishing a post

  Epic Options:
    * `:current_user` - user that will create the post, required.
    * `:post_attrs` (configurable) - attrs to create the post from, required.

  Act Options:
    * `:as` - key to assign changeset to, default: `:post`.
    * `:attrs` - epic options key to find the attributes at, default: `:post_attrs`.
  """

  alias Bonfire.Epics
  alias Bonfire.Social.Posts
  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Ecto.Acts.Work
  use Arrows
  import Epics
  import Where

  @doc false # see module documentation
  def run(epic, act) do
    current_user = epic.assigns[:options][:current_user]
    cond do
      epic.errors != [] ->
        maybe_debug(epic, act, length(epic.errors), "Skipping due to epic errors")
        epic
      not (is_struct(current_user) or is_binary(current_user)) ->
        maybe_debug(epic, act, current_user, "Skipping due to missing current_user")
        epic
      true ->
        as = Keyword.get(act.options, :as, :post)
        attrs_key = Keyword.get(act.options, :attrs, :post_attrs)
        attrs = Keyword.get(epic.assigns[:options], attrs_key, %{})
        boundary = epic.assigns[:options][:boundary]
        maybe_debug(epic, act, attrs_key, "Assigning changeset to :#{as} using attrs")
        # maybe_debug(epic, act, attrs, "Post attrs")
        if attrs == %{}, do: maybe_debug(act, attrs, "empty attrs")
        Posts.changeset(:create, attrs, current_user, boundary)
        |> Map.put(:action, :insert)
        |> Epic.assign(epic, as, ...)
        |> Work.add(:post)
    end
  end
end
