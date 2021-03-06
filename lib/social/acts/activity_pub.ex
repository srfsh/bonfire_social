defmodule Bonfire.Social.Acts.ActivityPub do
  @moduledoc """

  An Act that translates a post or changeset into some jobs for the
  AP publish worker. Handles creation, update and delete

  Act Options:
    * `on` - key in assigns to find the post, default: `:post`
    * `as` - key in assigns to assign indexable object, default: `:post_index`
  """

  alias Bonfire.Epics
  alias Bonfire.Epics.{Act, Epic}
  alias Bonfire.Data.Social.Post
  alias Bonfire.Social.Integration
  alias Ecto.Changeset
  import Epics
  import Where

  def run(epic, act) do
    on = Keyword.get(act.options, :on, :post)
    object = epic.assigns[on]
    current_user = epic.assigns[:options][:current_user]
    cond do
      epic.errors != [] ->
        maybe_debug(epic, act, length(epic.errors), "Skipping due to epic errors")
      is_nil(on) or not is_atom(on) ->
        maybe_debug(epic, act, on, "Skipping due to `on` option")
      not (is_struct(current_user) or is_binary(current_user)) ->
        warn(current_user, "Skipping due to missing current_user")
      true ->
        case object do
          %{id: _} -> Bonfire.Social.Integration.ap_push_activity(current_user.id, object)
          _ -> warn(object, "Skipping, not sure what to do with this")
        end
    end
    epic
  end
end
