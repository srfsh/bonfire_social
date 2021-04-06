defmodule Bonfire.Social.Posts do

  alias Bonfire.Data.Social.{Post, PostContent, Replied, Activity}
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Common.Utils
  alias Ecto.Changeset
  import Bonfire.Boundaries.Queries
  import Bonfire.Common.Hooks
  alias Bonfire.Social.Threads

  use Bonfire.Repo.Query,
      schema: Post,
      searchable_fields: [:id],
      sortable_fields: [:id]

  def draft(creator, attrs) do
    # TODO: create as private
    with {:ok, post} <- create(creator, attrs) do
      {:ok, post}
    end
  end

  def publish(creator, attrs) do
    #IO.inspect(attrs)
    hook_transact_with(fn ->
      with  {text, mentions, hashtags} <- Bonfire.Tag.TextContent.Process.process(creator, attrs),
            {:ok, post} <- create(creator, attrs, text),
            {:ok, maybe_tagged} <- maybe_tag(creator, post, mentions),
            {:ok, activity} <- FeedActivities.publish(creator, :create, Map.merge(post, maybe_tagged)) do

              Bonfire.Me.Users.Boundaries.maybe_make_visible_for(creator, post, Utils.e(attrs, :circles, nil))

              #IO.inspect(post)
              Threads.maybe_push_thread(creator, activity, post)

              {:ok, %{post: post, activity: activity}}
      end
    end)
  end

  defp maybe_tag(creator, post, tags) do
    if Utils.module_enabled?(Bonfire.Tag.Tags), do: Bonfire.Tag.Tags.maybe_tag(creator, post, tags), #|> IO.inspect
    else: {:ok, post}
    # {:ok, post}
  end


  # def reply(creator, attrs) do
  #   with  {:ok, published} <- publish(creator, attrs),
  #         {:ok, r} <- get_replied(published.post.id) do

  #     reply = Map.merge(r, published)
  #     # |> IO.inspect

  #     Utils.pubsub_broadcast(Utils.e(reply, :thread_id, nil), {:post_new_reply, reply}) # push to online users

  #     {:ok, reply}
  #   end
  # end

  defp create(%{id: creator_id}, attrs, text \\ nil) do
    attrs = attrs
      |> Map.put(:post_content, prepare_content(attrs, text))
      |> Map.put(:created, %{creator_id: creator_id})
      |> Map.put(:replied, Threads.maybe_reply(attrs))
      # |> IO.inspect

    repo().put(changeset(:create, attrs))
  end

  def prepare_content(attrs, text \\ nil)
  def prepare_content(%{post_content: %{} = attrs}, text), do: prepare_content(attrs, text)
  def prepare_content(attrs, text) when is_binary(text) and bit_size(text) > 0 do
    # use text overide if provided
    Map.merge(attrs, %{html_body: text})
  end
  def prepare_content(%{name: name, html_body: body} = attrs, _) when is_nil(body) or body=="" do
    # use title as body if no body entered
    Map.merge(attrs, %{html_body: name, name: ""})
  end
  def prepare_content(attrs, _), do: attrs


  defp changeset(:create, attrs) do
    Post.changeset(%Post{}, attrs)
    |> Changeset.cast_assoc(:post_content, [:required, with: &PostContent.changeset/2])
    |> Changeset.cast_assoc(:created)
    |> Changeset.cast_assoc(:replied, [:required, with: &Replied.changeset/2])
  end

  def read(post_id, current_user \\ nil) when is_binary(post_id) do

    with {:ok, post} <- build_query(id: post_id)
      |> Activities.object_preload_create_activity(current_user, [:default, :with_parents])
      |> Activities.as_permitted_for(current_user)
      # |> IO.inspect
      |> repo().single() do

        Utils.pubsub_subscribe(Utils.e(post, :activity, :replied, :thread_id, nil) || post.id) # subscribe to realtime feed updates

        {:ok, post} #|> repo().maybe_preload(controlled: [acl: [grants: [access: [:interacts]]]]) |> IO.inspect
      end
  end

  @doc "List posts created by the user and which are in their outbox, which are not replies"
  def list_by(by_user, current_user \\ nil, cursor_before \\ nil, preloads \\ :all) when is_binary(by_user) or is_list(by_user) do

    # query FeedPublish
    FeedActivities.build_query(feed_id: by_user, posts_by: by_user)
    |> FeedActivities.feed_query_paginated(current_user, cursor_before, preloads)
  end

  def get(id) when is_binary(id) do
    repo().single(get_query(id))
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

  def by_user(user_id) do
    repo().all(by_user_query(user_id))
  end

  def by_user_query(user_id) do
    from p in Post,
     left_join: pc in assoc(p, :post_content),
     left_join: cr in assoc(p, :created),
     where: cr.creator_id == ^user_id,
     preload: [post_content: pc, created: cr]
  end



end
