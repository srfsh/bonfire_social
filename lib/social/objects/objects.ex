defmodule Bonfire.Social.Objects do

  use Arrows
  use Bonfire.Repo,
    schema: Pointers.Pointer,
    searchable_fields: [:id],
    sortable_fields: [:id]
  use Bonfire.Common.Utils
  import Where

  alias Bonfire.Common
  alias Bonfire.Data.Identity.Character
  alias Bonfire.Boundaries.Acls
  alias Bonfire.Social.{Activities, Tags, Threads}

  @doc """
  Handles casting:
  * Creator
  * Caretaker
  * Threaded replies (when present)
  * Tags/Mentions (when present)
  * Acls
  * Activity
  * Feed Publishes
  """
  def cast(changeset, attrs, creator, preset_or_custom_boundary) do
    # debug(creator, "creator")
    changeset
    |> cast_creator_caretaker(creator)
    # record replies & threads. preloads data that will be checked by `Acls`
    |> Threads.cast(attrs, creator, preset_or_custom_boundary)
    # record tags & mentions. uses data preloaded by `PostContents`
    |> Tags.cast(attrs, creator, preset_or_custom_boundary)
    # apply boundaries on all objects, note that ORDER MATTERS, as it uses data preloaded by `Threads` and `PostContents`
    |> cast_acl(attrs, creator, preset_or_custom_boundary)
    |> cast_activity(attrs, creator, preset_or_custom_boundary)
    # |> debug()
  end

  @doc """
  Handles casting:
  * Creator
  * Caretaker
  * Acls
  """
  def cast_basic(changeset, attrs, creator, preset_or_custom_boundary) do
    changeset
    |> cast_creator_caretaker(creator)
    # apply boundaries on all objects, uses data preloaded by `Threads` and `PostContents`
    |> cast_acl(attrs, creator, preset_or_custom_boundary)
    # |> debug()
  end

  @doc """
  Handles casting:
  * Acls
  """
  def cast_mini(changeset, attrs, creator, preset_or_custom_boundary) do
    changeset
    # apply boundaries on all objects, uses data preloaded by `Threads` and `PostContents`
    |> cast_acl(attrs, creator, preset_or_custom_boundary)
    # |> debug()
  end

  @doc """
  Handles casting:
  * Acls
  * Activity
  * Feed Publishes
  """
  def cast_publish(changeset, attrs, creator, preset_or_custom_boundary) do
    # debug(creator, "creator")
    changeset
    |> cast_mini(attrs, creator, preset_or_custom_boundary)
    |> cast_activity(attrs, creator, preset_or_custom_boundary)
    # |> debug()
  end

  defp cast_acl(changeset, _attrs, creator, preset_or_custom_boundary) do
    changeset
    # apply boundaries on all objects, uses data preloaded by `Threads` and `PostContents`
    |> Acls.cast(creator, preset_or_custom_boundary)
  end

  defp cast_activity(changeset, %{id: id} = attrs, creator, preset_or_custom_boundary) when is_binary(id) do
    changeset
    |> Changeset.cast(attrs, [:id]) # manually set the ULID of the object (which will be the same as the Activity ID)
    # create activity & put in feeds
    |> Activities.cast(Map.get(attrs, :verb, :create), creator, preset_or_custom_boundary)
  end
  defp cast_activity(changeset, attrs, creator, preset_or_custom_boundary) do
    Map.put(attrs, :id, Pointers.ULID.generate())
    |> cast_activity(changeset, ..., creator, preset_or_custom_boundary)
  end

  def cast_creator(changeset, creator),
    do: cast_creator(changeset, creator, e(creator, :id, nil))

  def cast_creator(changeset, _creator, nil), do: changeset
  def cast_creator(changeset, _creator, creator_id) do
    changeset
    |> Changeset.cast(%{created: %{creator_id: creator_id}}, [])
    |> Changeset.cast_assoc(:created)
  end

  def cast_creator_caretaker(changeset, creator),
    do: cast_creator_caretaker(changeset, creator, e(creator, :id, nil))

  defp cast_creator_caretaker(changeset, _creator, nil), do: changeset
  defp cast_creator_caretaker(changeset, _creator, creator_id) do
    changeset
    |> Changeset.cast(%{created: %{creator_id: creator_id}}, [])
    |> Changeset.cast_assoc(:created)
    |> Changeset.cast(%{caretaker: %{caretaker_id: creator_id}}, [])
    |> Changeset.cast_assoc(:caretaker)
  end

  def read(object_id, socket_or_current_user) when is_binary(object_id) do
    current_user = current_user(socket_or_current_user) #|> debug
    Common.Pointers.pointer_query([id: object_id], socket_or_current_user)
    |> Activities.read(socket: socket_or_current_user, skip_boundary_check: true)
    # |> debug("object with activity")
    ~> maybe_preload_activity_object(current_user)
    ~> Activities.activity_under_object(...)
    ~> to_ok()
    # |> debug("final object")
  end

  def maybe_preload_activity_object(%{activity: %{object: _}} = pointer, current_user) do
    Common.Pointers.Preload.maybe_preload_nested_pointers(pointer, [activity: [:object]],
      current_user: current_user, skip_boundary_check: true)
  end
  def maybe_preload_activity_object(pointer, _current_user), do: pointer

  def preload_reply_creator(object) do
    object
    |> Bonfire.Repo.maybe_preload([replied: [reply_to: [created: [creator: [:character]]]]]) #|> IO.inspect
    # |> Bonfire.Repo.maybe_preload([replied: [:reply_to]]) #|> IO.inspect
    |> Bonfire.Repo.maybe_preload([replied: [reply_to: [creator: [:character]]]]) #|> IO.inspect
  end

  # TODO: does not take permissions into consideration
  def preload_creator(object),
    do: Bonfire.Repo.maybe_preload(object, [created: [creator: [:character]]])

  def object_creator(object) do
    e(object, :created, :creator, :character, e(object, :creator, nil))
  end

  defp tag_ids(tags), do: Enum.map(tags, &(&1.id))

  def preload_boundaries(list_of_assigns) do
    current_user = current_user(List.first(list_of_assigns))
    # |> debug("current_user")

    list_of_objects = list_of_assigns
    |> Enum.map(& e(&1, :object, nil))
    # |> debug("list_of_objects")

    list_of_ids = list_of_objects
    |> Enum.map(& e(&1, :id, nil))
    |> filter_empty([])
    # |> debug("list_of_ids")

    my_states = if current_user,
      do: Bonfire.Boundaries.Controlleds.list_on_objects(list_of_ids)
        |> Map.new(fn c -> { # Map.new discards duplicates for the same key, which is convenient for now as we only display one ACL (note that the order_by in the `list_on_objects` query matters)
          e(c, :id, nil),
          e(c, :acl, nil)
        } end),
      else: %{}

    # debug(my_states, "boundaries")

    list_of_assigns
    |> Enum.map(fn assigns ->
      object_id = e(assigns, :object, :id, nil)

      assigns
      # |> Map.put(
      #   :object_boundaries,
      #   Map.get(my_states, object_id)
      # )
      |> Map.put(
        :object_primary_boundary,
        Map.get(my_states, object_id)
          |> e(:named, nil)
      )
    end)
  end

  # # used for public and mentions presets. returns a list of feed ids
  # defp inboxes(tags) when is_list(tags), do: Enum.flat_map(tags, &inboxes/1)
  # defp inboxes(%{character: %Character{inbox: %Inbox{feed_id: id}}})
  # when not is_nil(id), do: [id]
  # defp inboxes(_), do: []

  # # used for public preset. if the creator is me, the empty list, else a list of one feed id
  # defp reply_to_inboxes(changeset, %{id: me}, "public") do
  #   case get_in(changeset, [:changes, :replied, :data, :reply_to]) do
  #     %{created: %{creator_id: creator}, character: %{inbox: %{feed_id: feed}}}
  #     when not is_nil(feed) and not is_nil(creator) and not creator == me -> [feed]
  #     _ -> []
  #   end
  # end
  # defp reply_to_inboxes(_, _, _), do: []


    # if we see tags, we load them and will one day verify you are permitted to use them
    # feeds = reply_to_inboxes(changeset, creator, preset) ++ inboxes(mentions)
    # with {:ok, activity} <- do_pub(subject, verb, object, circles) do
    #   # maybe_make_visible_for(subject, object, circles ++ tag_ids(tags))
    #   Threads.maybe_push_thread(subject, activity, object)
    #   notify(subject, activity, object, feeds)
    # end

end
