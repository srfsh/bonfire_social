defmodule Bonfire.Social.Feeds do
  use Bonfire.Common.Utils
  use Arrows
  import Where
  import Ecto.Query
  import Bonfire.Social.Integration
  import Where
  alias Bonfire.Data.Identity.Character
  alias Bonfire.Data.Social.Feed
  alias Bonfire.Social.Follows
  alias Bonfire.Social.Objects
  alias Bonfire.Me.Characters
  alias Bonfire.Boundaries


  # def queries_module, do: Feed
  def context_module, do: Feed

  def target_feeds(%Ecto.Changeset{} = changeset, creator, preset_or_custom_boundary) do
    # debug(changeset)

    # maybe include people, tags or other characters that were mentioned/tagged
    mentions = Utils.e(changeset, :changes, :post_content, :changes, :mentions, []) #|> debug("mentions")

    # maybe include the creator of what we're replying to
    reply_to_creator = Utils.e(changeset, :changes, :replied, :changes, :replying_to, :created, :creator, nil) #|> debug("reply_to")

    # include the thread as feed, so it can be followed
    thread_id = Utils.e(changeset, :changes, :replied, :changes, :thread_id, nil) || Utils.e(changeset, :changes, :replied, :changes, :replying_to, :thread_id, nil) #|> debug("thread_id")

    do_target_feeds(creator, preset_or_custom_boundary, mentions, reply_to_creator, thread_id)
  end

  def target_feeds(%{} = object, creator, preset_or_custom_boundary) do

    # FIXME: maybe include people, tags or other characters that were mentioned/tagged
    # mentions = Utils.e(object, :post_content, :mentions, []) #|> debug("mentions")

    # maybe include the creator of what we're replying to
    reply_to_creator = Utils.e(object, :replied, :reply_to, :created, :creator, nil) #|> debug("reply_to")

    # include the thread as feed, so it can be followed
    thread_id = Utils.e(object, :replied, :thread_id, nil) || Utils.e(object, :replied, :reply_to, :thread_id, nil) #|> debug("thread_id")

    do_target_feeds(creator, preset_or_custom_boundary, [], reply_to_creator, thread_id)
  end

  def do_target_feeds(creator, preset_or_custom_boundary, mentions \\ [], reply_to_creator \\ nil, thread_id \\ nil) do

    # include any extra feeds specified in opts
    to_feeds_extra = maybe_custom_feeds(preset_or_custom_boundary) || []
    |> debug("to_feeds_extra")

    []
    ++ [to_feeds_extra]
    ++ case Boundaries.preset(preset_or_custom_boundary) do

      "public" -> # put in all reply_to creators and mentions inboxes + guest/local feeds
        [ named_feed_id(:guest),
          named_feed_id(:local),
          feed_id(:notifications, reply_to_creator),
          thread_id,
          my_feed_id(:outbox, creator)
        ]
        ++ feed_ids(:notifications, mentions)

      "federated" -> # like public but put in federated instead of local (is this what we want?)
      [ named_feed_id(:guest),
        named_feed_id(:activity_pub),
        feed_id(:notifications, reply_to_creator),
        thread_id,
        my_feed_id(:outbox, creator)
      ]
      ++ feed_ids(:notifications, mentions)

      "local" ->

        [named_feed_id(:local)] # put in local instance feed
        ++
        [( # put in inboxes (notifications) of any local reply_to creators and mentions
          ([reply_to_creator]
           ++ mentions)
          |> Enum.filter(&is_local?/1)
          |> feed_id(:notifications, ...)
        )] ++ [
          thread_id,
          my_feed_id(:outbox, creator)
        ]

      "mentions" ->
        feed_ids(:notifications, mentions)

      "admins" ->
        admins_notifications()

      _ -> [] # default to none except any custom ones
    end
    |> List.flatten()
    |> Utils.filter_empty([])
    |> Enum.uniq()
    |> debug("target feeds")
  end

   def maybe_custom_feeds(preset_and_custom_boundary), do: Boundaries.maybe_from_opts(preset_and_custom_boundary, :to_feeds)

  def named_feed_id(name) when is_atom(name), do: Bonfire.Boundaries.Circles.get_id(name)
  def named_feed_id(name) when is_binary(name) do
    case maybe_to_atom(name) do
      named when is_atom(named) -> named_feed_id(named)
      _ ->
        warn("Feed: doesn't seem to be a named feed: #{inspect name}")
        nil
    end
  end

  def my_home_feed_ids(socket, extra_feeds \\ [])
  # TODO: make configurable if user wants notifications included in home feed

  def my_home_feed_ids(socket_or_opts, extra_feeds) do
    # debug(my_home_feed_ids_user: user)

    current_user = current_user(socket_or_opts)

    # include my outbox
    my_outbox_id = my_feed_id(:outbox, current_user) #|> debug("my_outbox_id")

    # include my notifications?
    extra_feeds = extra_feeds ++ [my_outbox_id] ++
      if e(socket_or_opts, :include_notifications?, false), do: [my_feed_id(:notifications, current_user)], else: []

    # include outboxes of everyone I follow
    with _ when not is_nil(current_user) <- current_user,
         followings when is_list(followings) <- Follows.all_followed_outboxes(current_user, skip_boundary_check: true) do
      # debug(followings, "followings")
      extra_feeds ++ followings
    else
      _e ->
        #debug(e: e)
        extra_feeds
    end
    |> Utils.filter_empty([])
    |> Enum.uniq()
    # |> debug("all")
  end

  def my_home_feed_ids(_, extra_feeds), do: extra_feeds

  def my_feed_id(type, other) do
    case current_user(other) do
      nil ->
        error("Social.Feeds.my_feed_id: no user found in #{inspect other}")
        nil

      current_user ->
        # debug(current_user, "looking up feed for user")
        feed_id(type, current_user)
    end
  end

  def feed_ids(feed_name, for_subjects) when is_list(for_subjects) do
    for_subjects
    |> repo().maybe_preload([:character])
    |> Enum.map(&feed_id(feed_name, &1))
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
  # def feed_ids(feed_name, for_subject), do: feed_id(feed_name, for_subject)


  # def feed_id(type, for_subjects) when is_list(for_subjects), do: feed_ids(type, for_subjects)

  def feed_id(type, %{character: _} = object), do: repo().maybe_preload(object, :character) |> e(:character, nil) |> feed_id(type, ...)

  def feed_id(feed_name, for_subject) do
    cond do
      is_binary(for_subject) ->
        Characters.get(for_subject)
        ~> feed_id(feed_name, ...)

      is_atom(feed_name) ->
        # debug(for_subject, "subject before looking for feed")

        (feed_key(feed_name) #|> debug()
          |> e(for_subject, ..., nil))
        # || maybe_create_feed(feed_name, for_subject) # shouldn't be needed because feeds are cast into Character changeset

      # is_list(feed_name) ->
      #   Enum.map(feed_name, &feed_id!(user, &1))
      #   |> Enum.reject(&is_nil/1)

      true ->
        nil
    end
  end
  def feed_id!(feed_name, for_subject) do
    feed_id(feed_name, for_subject) || raise "Expected feed name and user or character, got #{inspect(feed_name)}"
  end

  @typedoc "Names a predefined feed attached to a user"
  @type feed_name :: :inbox | :outbox | :notifications

  defp feed_key(:inbox),  do: :inbox_id
  defp feed_key(:outbox), do: :outbox_id
  defp feed_key(:notifications), do: :notifications_id
  defp feed_key(:notification), do: :notifications_id # just in case
  defp feed_key(other), do: raise "Unknown user feed name: #{inspect(other)}"


  def inbox_of_obj_creator(object) do
    Objects.preload_creator(object) |> Objects.object_creator() |> feed_id(:notifications, ...) #|> IO.inspect
  end

  # def admins_inboxes(), do: Bonfire.Me.Users.list_admins() |> admins_inboxes()
  # def admins_inboxes(admins) when is_list(admins), do: Enum.map(admins, fn x -> admin_inbox(x) end)
  # def admin_inbox(admin) do
  #   admin = admin |> Bonfire.Repo.maybe_preload([:character]) # |> IO.inspect
  #   #|> debug()
  #   e(admin, :character, :inbox_id, nil)
  #     || feed_id(:inbox, admin)
  # end

  def admins_notifications(), do:
    Bonfire.Me.Users.list_admins()
    |> Bonfire.Repo.maybe_preload([:character])
    |> admins_notifications()
  def admins_notifications(admins) when is_list(admins), do: Enum.map(admins, fn x -> admin_notifications(x) end)
  def admin_notifications(admin) do
    e(admin, :character, :notifications_id, nil)
    || feed_id(:notifications, admin)
  end

  def maybe_create_feed(type, for_subject) do
    with feed_id when is_binary(feed_id) <- create_box(type, for_subject) do
      # debug(for_subject)
      debug("Feeds: created new #{inspect type} with id #{inspect feed_id} for #{inspect ulid(for_subject)}")
      feed_id
    else e ->
      error("Feeds.feed_id: could not find or create feed (#{inspect e}) for #{inspect ulid(for_subject)}")
      nil
    end
  end

  @doc """
  Create an inbox or outbox for an existing Pointable (eg. User)
  """
  defp create_box(type, %Character{id: _}=character) do
    # TODO: optimise using cast_assoc?
    with {:ok, %{id: feed_id} = _feed} <- create(),
         {:ok, character} <- save_box_feed(type, character, feed_id) do
      feed_id
    else e ->
      debug("Social.Feeds: could not create_box for #{inspect character}")
      nil
    end
  end
  defp create_box(_type, other) do
    debug("Social.Feeds: no clause match for function create_box with #{inspect other}")
    nil
  end

  defp save_box_feed(:outbox, character, feed_id) do
    update_character(character, %{outbox_id: feed_id})
  end
  defp save_box_feed(:inbox, character, feed_id) do
    update_character(character, %{inbox_id: feed_id})
  end
  defp save_box_feed(:notifications, character, feed_id) do
    update_character(character, %{notifications_id: feed_id})
  end

  defp update_character(%Character{} = character, attrs) do
    repo().update(Character.changeset(character, attrs, :update))
  end


  @doc """
  Create a new generic feed
  """
  defp create() do
    do_create(%{})
  end

  @doc """
  Create a new feed with a specific ID
  """
  defp create(%{id: id}) do
    do_create(%{id: id})
  end

  defp do_create(attrs) do
    repo().put(changeset(attrs))
  end

  defp changeset(activity \\ %Feed{}, %{} = attrs) do
    Feed.changeset(activity, attrs)
  end

end
