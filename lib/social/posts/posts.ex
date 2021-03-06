defmodule Bonfire.Social.Posts do

  use Arrows
  import Where
  import Bonfire.Boundaries.Queries
  alias Bonfire.Data.Social.{Post, PostContent, Replied, Activity}
  alias Bonfire.Social.{Activities, FeedActivities, Feeds, Objects}
  alias Bonfire.Boundaries.{Circles, Verbs}
  alias Bonfire.Epics.Epic
  alias Bonfire.Social.{Integration, PostContents, Tags, Threads}
  alias Ecto.Changeset

  use Bonfire.Repo,
    schema: Post,
    searchable_fields: [:id],
    sortable_fields: [:id]

  use Bonfire.Common.Utils

  # import Bonfire.Boundaries.Queries

  def queries_module, do: Post
  def context_module, do: Post
  def federation_module, do: [
    {"Create", "Note"},
    {"Update", "Note"},
    {"Create", "Article"},
    {"Update", "Article"}
  ]

  def draft(creator, attrs) do
    # TODO: create as private
    # with {:ok, post} <- create(creator, attrs) do
    #   {:ok, post}
    # end
  end

  def publish(options \\ []) do
    options = Keyword.merge(options, crash: true, debug: false, verbose: false)
    epic =
      Epic.from_config!(__MODULE__, :publish)
      |> Epic.assign(:options, options)
      |> Epic.run()
    if epic.errors == [], do: {:ok, epic.assigns.post}, else: {:error, epic}
  end


  # def reply(creator, attrs) do
  #   with  {:ok, published} <- publish(creator, attrs),
  #         {:ok, r} <- get_replied(published.post.id) do
  #     reply = Map.merge(r, published)
  #     # |> IO.inspect

  #     pubsub_broadcast(e(reply, :thread_id, nil), {{Bonfire.Social.Posts, :new_reply}, reply}) # push to online users

  #     {:ok, reply}
  #   end
  # end

  def changeset(action, attrs, creator \\ nil, preset \\ nil)

  def changeset(:create, attrs, _creator, _preset) when attrs == %{} do
    # keep it simple for forms

    Post.changeset(%Post{}, attrs)
  end

  def changeset(:create, attrs, creator, preset_or_custom_boundary) do
    attrs
    # |> debug("attrs")
    |> Post.changeset(%Post{}, ...)
    |> PostContents.cast(attrs, creator, preset_or_custom_boundary) # process text (must be done before Objects.cast)
    |> Objects.cast(attrs, creator, preset_or_custom_boundary) # deal with threading, tagging, boundaries, activities, etc.
  end

  def read(post_id, opts_or_socket_or_current_user \\ []) when is_binary(post_id) do
    with {:ok, post} <- base_query([id: post_id], opts_or_socket_or_current_user)
      |> Activities.read(opts_or_socket_or_current_user) do
        {:ok, Activities.activity_under_object(post) }
      end
  end

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list_by(by_user, opts_or_current_user \\ []) do
    # query FeedPublish
    [posts_by: {by_user, &filter/3}]
    |> list_paginated(opts_or_current_user)
  end

  @doc "List posts with pagination"
  def list_paginated(filters, opts_or_current_user \\ [])
  def list_paginated(filters, opts_or_current_user) when is_list(filters) do
    paginate = e(opts_or_current_user, :paginate, opts_or_current_user)
    filters
    # |> debug("Posts.list_paginated:filters")
    |> query_paginated(opts_or_current_user)
    |> Bonfire.Repo.many_paginated(paginate)
    # |> FeedActivities.feed_paginated(filters, opts_or_current_user)
  end

  @doc "Query posts with pagination"
  def query_paginated(filters, opts_or_current_user \\ [])
  def query_paginated(filters, opts_or_current_user) when is_list(filters) do
    filters
    # |> debug("Posts.query_paginated:filters")
    |> Keyword.drop([:paginate])
    |> FeedActivities.query_paginated(opts_or_current_user, Post)
    # |> debug("after FeedActivities.query_paginated")
  end
  # query_paginated(filters \\ [], current_user_or_socket_or_opts \\ [],  query \\ FeedPublish)
  def query_paginated({a,b}, opts_or_current_user), do: query_paginated([{a,b}], opts_or_current_user)

  def query(filters \\ [], opts_or_current_user \\ nil)

  def query(filters, opts_or_current_user) when is_list(filters) or is_tuple(filters) do
    q = base_query(filters, opts_or_current_user)
        |> join_preload([:post_content])
        |> boundarise(main_object.id, opts_or_current_user)
  end

  defp base_query(filters, opts_or_current_user) when is_list(filters) or is_tuple(filters) do
    (from p in Post, as: :main_object)
    |> query_filter(filters, nil, nil)
  end

  #doc "List posts created by the user and which are in their outbox, which are not replies"
  def filter(:posts_by, user, query) do
    # user = repo().maybe_preload(user, [:character])
    verb_id = Verbs.get_id!(:create)
    query
    |> proload(activity: [object: {"object_", [:replied]}])
    |> where(
      [activity: activity, object_replied: replied],
      is_nil(replied.reply_to_id)
      and activity.verb_id==^verb_id
      and activity.subject_id == ^ulid(user)
    )
  end


  def ap_publish_activity("create", post) do
    attrs = ap_publish_activity_object("create", post)
    ActivityPub.create(attrs, post.id)
  end

  # in an ideal world this would be able to work off the changeset, but for now, fuck it.
  def ap_publish_activity_object("create", post) do
    post = post
    |> repo().maybe_preload([:created, :replied, :post_content, tags: [:character]])
    |> Activities.object_preload_create_activity()
    # |> dump("ap_publish_activity post")

    {:ok, actor} = ActivityPub.Adapter.get_actor_by_id(e(post, :activity, :subject_id, nil) || e(post, :created, :creator_id, nil))

    published_in_feeds = Bonfire.Social.FeedActivities.feeds_for_activity(post.activity) |> debug("published_in_feeds")

    #FIXME only publish to public URI if in a public enough cirlce
    #Everything is public atm
    to =
      if Bonfire.Boundaries.Circles.get_id!(:guest) in published_in_feeds do
        ["https://www.w3.org/ns/activitystreams#Public"]
      else
       []
      end

    # TODO: find a better way of deleting non actor entries from the list
    # (or represent them in AP)
    direct_recipients =
      e(post, :tags, [])
      |> Enum.reject(fn tag -> is_nil(e(tag, :character, :id, nil)) or tag.id == e(post, :activity, :subject_id, nil) or tag.id == e(post, :created, :creator_id, nil) end)
      # |> debug("mentions")
      |> Enum.map(fn tag -> ActivityPub.Actor.get_by_local_id!(tag.id) end)
      |> filter_empty([])
      |> Enum.map(fn actor -> actor.ap_id end)
      |> debug("direct_recipients")

    cc = [actor.data["followers"]]

    object = %{
      "type" => "Note",
      "actor" => actor.ap_id,
      "attributedTo" => actor.ap_id,
      "name" => (e(post, :post_content, :name, nil)),
      "summary" => (e(post, :post_content, :summary, nil)),
      "content" => (e(post, :post_content, :html_body, nil)),
      "to" => to ++ direct_recipients,
      "cc" => cc
    }
      |> Enum.filter(fn {_, v} -> not is_nil(v) end)
      |> Enum.into(%{})

    object =
      if e(post, :replied, :reply_to_id, nil) do
        ap_object = ActivityPub.Object.get_cached_by_pointer_id(post.replied.reply_to_id)
        Map.put(object, "inReplyTo", ap_object.data["id"])
      else
        object
      end

    %{
      actor: actor,
      context: ActivityPub.Utils.generate_context_id(),
      object: object,
      to: to ++ direct_recipients,
      additional: %{
        "cc" => cc
      }
    }
  end

  @doc """
  record an incoming ActivityPub post
  """
  def ap_receive_activity(creator, activity, object, circles \\ [])

  def ap_receive_activity(creator, activity, %{public: true} = object, []) do
    ap_receive_activity(creator, activity, object, [:guest])
  end

  def ap_receive_activity(creator, %{data: _activity_data} = _activity, %{data: post_data, pointer_id: id} = _object, circles) do # record an incoming post
    # debug(activity: activity)
    # debug(creator: creator)
    # debug(object: object)

    direct_recipients = post_data["to"] || []

    direct_recipients =
      direct_recipients
      |> List.delete(Bonfire.Federate.ActivityPub.Utils.public_uri())
      |> Enum.map(fn ap_id -> Bonfire.Me.Users.by_ap_id!(ap_id) end)
      |> Enum.filter(fn x -> not is_nil(x) end)
      |> Enum.map(fn user -> user.id end)

    attrs = %{
      id: id,
      local: false, # FIXME?
      canonical_url: nil, # TODO, in a mixin?
      to_circles: circles ++ direct_recipients,
      post_content: %{
        name: post_data["name"],
        html_body: post_data["content"]
      },
      created: %{
        date: post_data["published"] # FIXME
      }
    }

    attrs =
      if post_data["inReplyTo"] do
        case ActivityPub.Object.get_cached_by_ap_id(post_data["inReplyTo"]) do
          nil -> attrs
          object -> Map.put(attrs, :reply_to_id, object.pointer_id)
        end
      else
        attrs
      end

    publish(current_user: creator, post_attrs: attrs, boundary: "federated")
  end

  # TODO: rewrite to take a post instead of an activity
  def indexing_object_format(post, opts \\ []) do
    case post do
      # The indexer is written in terms of the inserted object, so changesets need fake inserting
      %{id: id, post_content: content, activity: %{subject: %{profile: profile, character: character} = activity}} ->
        %{ "id" => id,
           "index_type" => "Bonfire.Data.Social.Post",
           # "url" => path(post),
           "post_content" => PostContents.indexing_object_format(content),
           "creator" => Bonfire.Me.Integration.indexing_format(profile, character), # this looks suspicious
           "tag_names" => Tags.indexing_format_tags(activity)
         } #|> IO.inspect
      _ ->
        error("Posts: no clause match for function indexing_object_format/3")
        error(post, "post")
        nil
    end
  end

  def maybe_index(post, options \\ []) do
    indexing_object_format(post, options)
    |> Bonfire.Social.Integration.maybe_index()
    {:ok, post}
  end

end
