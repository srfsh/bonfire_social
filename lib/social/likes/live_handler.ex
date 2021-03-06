defmodule Bonfire.Social.Likes.LiveHandler do
  use Bonfire.Web, :live_handler
  import Where

  def handle_event("like", %{"direction"=>"up", "id"=> id} = params, socket) do # like in LV
    #debug(socket)

    with %{id: _} = current_user <- current_user(socket),
         {:ok, like} <- Bonfire.Social.Likes.like(current_user, id) do
      set_liked(id, like, params, socket)

    else {:error, %Ecto.Changeset{errors: [
       liker_id: {"has already been taken",
        _}
     ]}} ->
      debug("previously liked, but UI didn't know")
      set_liked(id, %{id: true}, params, socket)
    end
  end

  def set_liked(id, like, params, socket) do
    set = [
        my_like: true,
        # like_count: liker_count(params)+1,
      ]

      ComponentID.send_assigns(e(params, "component", Bonfire.UI.Social.LikeActionLive), id, set, socket)

  end


  def handle_event("like", %{"direction"=>"down", "id"=> id} = params, socket) do # unlike in LV
    with _ <- Bonfire.Social.Likes.unlike(current_user(socket), id) do
      set = [
      my_like: false,
      # like_count: liker_count(params)-1
      ]

    ComponentID.send_assigns(e(params, "component", Bonfire.UI.Social.LikeActionLive), id, set, socket)

    end
  end


  def liker_count(%{"current_count"=> a}), do: a |> String.to_integer
  def liker_count(%{current_count: a}), do: a |> String.to_integer
  # def liker_count(%{assigns: a}), do: liker_count(a)
  # def liker_count(%{like_count: like_count}), do: liker_count(like_count)
  # def liker_count(%{liker_count: liker_count}), do: liker_count(liker_count)
  # def liker_count(liker_count) when is_integer(liker_count), do: liker_count
  def liker_count(_), do: 0

  def preload(list_of_assigns) do
    current_user = current_user(List.first(list_of_assigns))
    # |> debug("current_user")
    # debug(list_of_assigns, "list of assign:")
    list_of_objects = list_of_assigns
    |> Enum.map(& e(&1, :object, nil))
    |> repo().maybe_preload(:like_count)
    # |> debug("list_of_objects")

    list_of_ids = list_of_objects
    |> Enum.map(& e(&1, :id, nil))
    |> filter_empty([])
    # |> debug("list_of_ids")

    my_states = if current_user, do: Bonfire.Social.Likes.get!(current_user, list_of_ids, preload: false) |> Map.new(fn l -> {e(l, :edge, :object_id, nil), true} end), else: %{}
    # debug(my_states, "my_likes")

    objects_counts = list_of_objects |> Map.new(fn o -> {e(o, :id, nil), e(o, :like_count, :object_count, nil)} end)
    # |> debug("like_counts")

    list_of_assigns
    |> Enum.map(fn assigns ->
      object_id = e(assigns, :object, :id, nil)
      value = if current_user, do: Map.get(my_states, object_id), else: Map.get(List.first(list_of_assigns), :my_like)

      assigns
      |> Map.put(
        :my_like,
        value
      )
      |> Map.put(
        :like_count,
        Map.get(objects_counts, object_id)
      )
    end)
  end

end
