defmodule Bonfire.Social.Posts do

  alias Bonfire.Data.Social.{Post, PostContent, Replied, Activity}
  alias Bonfire.Social.{Activities, FeedActivities, Objects}
  alias Ecto.Changeset
  # import Bonfire.Boundaries.Queries
  alias Bonfire.Social.Threads
  alias Bonfire.Social.PostContents
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Social.Integration

  import Bonfire.Common.Utils

  use Bonfire.Repo,
      schema: Post,
      searchable_fields: [:id],
      sortable_fields: [:id]

  def queries_module, do: Post
  def context_module, do: Post
  def federation_module, do: [{"Create", "Note"}, {"Update", "Note"}, {"Create", "Article"}, {"Update", "Article"}]

  def draft(creator, attrs) do
    # TODO: create as private
    with {:ok, post} <- create(creator, attrs) do
      {:ok, post}
    end
  end

  def publish(%{} = creator, attrs, preset_boundary \\ nil) do
    # TODO: make mentions_are_private? and replies_are_private? defaults configurable
    # IO.inspect(attrs: attrs)
    to_circles = e(attrs, :to_circles, [])

    tag_characters_should_boost_mentions? = preset_boundary == "public" or :guest in to_circles or Bonfire.Boundaries.Circles.circles()[:guest] in to_circles

    repo().transact_with(fn ->
      with  {text, mentions, hashtags} <- Bonfire.Tag.TextContent.Process.process(creator, attrs, "text/markdown"),
        {:ok, post} <- create(creator, attrs, text),
        {:ok, post_with_tags} <- Bonfire.Social.Tags.maybe_tag(creator, post, mentions, tag_characters_should_boost_mentions?),
        {:ok, activity} <- FeedActivities.publish(creator, :create, post_with_tags, to_circles, preset_boundary) do

          post_with_activity = Activities.activity_under_object(activity)

          maybe_index(activity)

          {:ok, post_with_activity}

      end
    end)
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

  defp create(%{id: creator_id}, attrs, text \\ nil) do
    attrs = attrs
      |> Map.put(:post_content, PostContents.prepare_content(attrs, text))
      |> Map.put(:created, %{creator_id: creator_id})
      |> Map.put(:replied, Threads.maybe_reply(attrs))
      # |> IO.inspect(label: "Posts.create attrs")

    repo().put(changeset(:create, attrs))
  end


  def changeset(:create, attrs) do
    Post.changeset(%Post{}, attrs)
    |> Changeset.cast_assoc(:post_content, [:required, with: &PostContents.changeset/2])
    |> Changeset.cast_assoc(:created)
    |> Changeset.cast_assoc(:replied, [:required, with: &Replied.changeset/2])
  end

  def read(post_id, socket_or_current_user \\ nil, preloads \\ :all) when is_binary(post_id) do

    current_user = current_user(socket_or_current_user)

    with {:ok, post} <- base_query([id: post_id], current_user, preloads)
      |> Activities.read(socket_or_current_user) do

        {:ok, Activities.activity_under_object(post) }

      end
  end

  @doc """
  For internal use only (doesn't check permissions). Use `read` instead.
  """
  def get(id) when is_binary(id) do
    repo().single(get_query(id))
  end

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list_by(by_user, opts_or_current_user \\ [], preloads \\ :all) when is_binary(by_user) or is_list(by_user) do

    # query FeedPublish
    [feed_id: by_user, posts_by: {by_user, &filter/3}]
    |> list_paginated(opts_or_current_user, preloads)
  end

  @doc "List posts with pagination"
  def list_paginated(filters, opts_or_current_user \\ [], preloads \\ :all)
  def list_paginated(filters, opts_or_current_user, preloads) when is_list(filters) do

    filters
    # |> IO.inspect()
    |> query_paginated(opts_or_current_user, preloads)
    |> FeedActivities.feed_paginated(opts_or_current_user, filters, preloads)
  end

  @doc "Query posts with pagination"
  def query_paginated(filters, opts_or_current_user \\ [], preloads \\ :all)
  def query_paginated(filters, opts_or_current_user, preloads) when is_list(filters) do

    filters
    # |> IO.inspect()
    |> Keyword.drop([:paginate])
    |> FeedActivities.query_paginated(opts_or_current_user, filters, preloads)
  end
  def query_paginated({a,b}, opts_or_current_user, preloads), do: query_paginated([{a,b}], opts_or_current_user, preloads)

  def query(filters \\ [], opts_or_current_user \\ nil, preloads \\ :all)

  def query(filters, opts_or_current_user, preloads) when is_list(filters) or is_tuple(filters) do

    q = base_query(filters, opts_or_current_user, preloads)
        |> join_preload([:post_content])

    maybe_apply(Bonfire.Boundaries.Queries, :object_only_visible_for, [q, opts_or_current_user], q)
  end

  defp base_query(filters, opts_or_current_user, preloads) when is_list(filters) or is_tuple(filters) do

    (from p in Post, as: :main_object)
    |> query_filter(filters, nil, nil)
  end

  #doc "List posts created by the user and which are in their outbox, which are not replies"
  def filter(:posts_by, user_id, query) when is_binary(user_id) do
    verb_id = Verbs.verbs()[:create]

    query
      |> join_preload([:activity, :object_post])
      |> join_preload([:activity, :object_created])
      |> join_preload([:activity, :replied])
      |> where(
        [activity: activity, object_post: post, object_created: created, replied: replied],
        is_nil(replied.reply_to_id) and not is_nil(post.id) and activity.verb_id==^verb_id and created.creator_id == ^user_id
      )
  end

  def get_query(id) do
    from p in Post,
     left_join: pc in assoc(p, :post_content),
     left_join: cr in assoc(p, :created),
     left_join: re in assoc(p, :replied),
     left_join: rt in assoc(re, :reply_to),
     where: p.id == ^id,
     preload: [post_content: pc, created: cr, replied: {re, [reply_to: rt]}]
  end

  defp by_user(user_id) do
    repo().many(by_user_query(user_id))
  end

  defp by_user_query(user_id) do
    from p in Post,
     left_join: pc in assoc(p, :post_content),
     left_join: cr in assoc(p, :created),
     where: cr.creator_id == ^user_id,
     preload: [post_content: pc, created: cr]
  end

  def ap_publish_activity("create", post) do

    post = post
    |> repo().maybe_preload([:created, :replied, :post_content])
    |> Activities.object_preload_create_activity()
    # |> IO.inspect(label: "ap_publish_activity post")

    {:ok, actor} = ActivityPub.Adapter.get_actor_by_id(e(post, :activity, :subject_id, nil) || e(post, :created, :creator_id, nil))

    #FIXME only publish to public URI if in a public enough cirlce
    #Everything is public atm
    to =
      # if Bonfire.Boundaries.Circles.circles[:guest] in Bonfire.Social.FeedActivities.feeds_for_activity(post.activity) do
        ["https://www.w3.org/ns/activitystreams#Public"]
      # else
      #  []
      # end

    # TODO: find a better way of deleting non actor entries from the list
    # (or represent them in AP)
    direct_recipients =
      Bonfire.Social.FeedActivities.feeds_for_activity(post.activity)
      |> List.delete(e(post, :activity, :subject_id, nil) || e(post, :created, :creator_id, nil))
      |> List.delete(Bonfire.Boundaries.Circles.circles[:guest])
      |> Enum.map(fn id -> ActivityPub.Actor.get_by_local_id!(id) end)
      |> Enum.filter(fn x -> not is_nil(x) end)
      |> Enum.map(fn actor -> actor.ap_id end)

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

    object =
      if e(post, :replied, :reply_to_id, nil) do
        ap_object = ActivityPub.Object.get_cached_by_pointer_id(post.replied.reply_to_id)
        Map.put(object, "inReplyTo", ap_object.data["id"])
      else
        object
      end

    attrs = %{
      actor: actor,
      context: ActivityPub.Utils.generate_context_id(),
      object: object,
      to: to ++ direct_recipients,
      additional: %{
        "cc" => cc
      }
    }

    ActivityPub.create(attrs, post.id)
  end

  @doc """
  record an incoming post
  """
  def ap_receive_activity(creator, activity, object, circles \\ [])

  def ap_receive_activity(creator, activity, %{public: true} = object, []) do
    ap_receive_activity(creator, activity, object, [:guest])
  end

  def ap_receive_activity(creator, %{data: _activity_data} = _activity, %{data: post_data} = _object, circles) do # record an incoming post
    # IO.inspect(activity: activity)
    # IO.inspect(creator: creator)
    # IO.inspect(object: object)

    direct_recipients = post_data["to"] || []

    direct_recipients =
      direct_recipients
      |> List.delete(Bonfire.Federate.ActivityPub.Utils.public_uri())
      |> Enum.map(fn ap_id -> Bonfire.Me.Users.by_ap_id!(ap_id) end)
      |> Enum.filter(fn x -> not is_nil(x) end)
      |> Enum.map(fn user -> user.id end)

    attrs = %{
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

    with {:ok, post} <- publish(creator, attrs, "public") do
      # IO.inspect(remote_post: post)
      {:ok, post}
    end
  end


  def indexing_object_format(feed_activity_or_activity, object \\ nil)
  def indexing_object_format(%{subject_profile: subject_profile, subject_character: subject_character} = activity, %{id: id, post_content: post_content} = post) do

    # IO.inspect(obj)

    %{
      "id" => id,
      "index_type" => "Bonfire.Data.Social.Post",
      # "url" => path(post),
      "post_content" => PostContents.indexing_object_format(post_content),
      "creator" => Bonfire.Me.Integration.indexing_format(subject_profile, subject_profile),
      "tag_names" => Bonfire.Social.Integration.indexing_format_tags(activity)
    } #|> IO.inspect
  end
  def indexing_object_format(%{activity: %{object: object} = activity}, nil), do: indexing_object_format(activity, object)
  def indexing_object_format(%Activity{object: object} = activity, nil), do: indexing_object_format(activity, object)
  def indexing_object_format(a, b) do
    Logger.error("Posts: could not indexing_object_format")
    IO.inspect(a)
    IO.inspect(b)
    nil
  end

  def maybe_index(object), do: indexing_object_format(object) |> Bonfire.Social.Integration.maybe_index()


end
