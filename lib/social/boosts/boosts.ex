defmodule Bonfire.Social.Boosts do

  alias Bonfire.Data.Identity.User
  alias Bonfire.Data.Social.Boost
  alias Bonfire.Boundaries.Verbs
  # alias Bonfire.Data.Social.BoostCount
  alias Bonfire.Social.{Activities, FeedActivities}
  alias Bonfire.Social.Edges

  use Bonfire.Repo,
    searchable_fields: [:booster_id, :boosted_id]
  # import Bonfire.Me.Integration
  import Bonfire.Common.Utils


  def queries_module, do: Boost
  def context_module, do: Boost
  def federation_module, do: ["Announce", {"Create", "Announce"}, {"Undo", "Announce"}, {"Delete", "Announce"}]

  def boosted?(%{}=user, object), do: not is_nil(get!(user, object))

  def get(subject, object), do: [subject: subject, object: object] |> query(current_user: subject) |> repo().single()
  def get!(subject, objects) when is_list(objects), do: [subject: subject, object: objects] |> query(current_user: subject) |> repo().all()
  def get!(subject, object), do: [subject: subject, object: object] |> query(current_user: subject) |> repo().one()

  # def by_booster(%{}=user), do: repo().many(by_booster_q(user))
  # def by_boosted(%{}=user), do: repo().many(by_boosted_q(user))
  # def by_any(%{}=user), do: repo().many(by_any_q(user))

  def boost(%{} = booster, %{} = boosted) do
    with {:ok, boost} <- create(booster, boosted),
    {:ok, published} <- FeedActivities.publish(booster, :boost, boosted) do
      # TODO: increment the boost count

      FeedActivities.maybe_notify_creator(booster, published, boosted) #|> IO.inspect

      with_activity = Activities.activity_under_object(published, boost) #|> IO.inspect()
      {:ok, with_activity}
    end
  end
  def boost(%{} = booster, boosted) when is_binary(boosted) do
    with {:ok, boosted} <- Bonfire.Common.Pointers.get(boosted, current_user: booster) do
      #IO.inspect(liked)
      boost(booster, boosted)
    end
  end

  def unboost(%{}=booster, %{}=boosted) do
    delete_by_both(booster, boosted) # delete the Boost
    Activities.delete_by_subject_verb_object(booster, :boost, boosted) # delete the boost activity & feed entries
    # TODO: decrement the boost count
  end
  def unboost(%{} = booster, boosted) when is_binary(boosted) do
    with {:ok, boosted} <- Bonfire.Common.Pointers.get(boosted, current_user: booster) do
      #IO.inspect(liked)
      unboost(booster, boosted)
    end
  end

  @doc "List current user's boosts"
  def list_my(opts) do
    list_by(current_user(opts), opts)
  end

  @doc "List boosts by the user "
  def list_by(by_user, opts \\ []) when is_binary(by_user) or is_list(by_user) or is_map(by_user) do

    # query FeedPublish
    [subject: by_user]
    |> list_paginated(opts)
  end

  @doc "List boost of an object"
  def list_of(id, opts \\ []) when is_binary(id) or is_list(id) or is_map(id) do

    # query FeedPublish
    [object: id]
    |> list_paginated(opts)
  end

  def list_paginated(filters, opts \\ []) do
    filters
    |> query(opts)
    |> Bonfire.Repo.many_paginated(opts)
    # TODO: activity preloads
  end

  defp query_base(filters, opts) do
    Edges.query(Boost, filters, opts)
    # |> proload(edge: [
    #   # subject: {"booster_", [:profile, :character]},
    #   # object: {"boosted_", [:profile, :character, :post_content]}
    #   ])
    # |> query_filter(filters)
  end

  def query([my: :boosts], opts), do: [subject: current_user(opts)] |> query(opts)

  def query(filters, opts) do
    query_base(filters, opts)
  end


  defp create(booster, boosted) do
    changeset(booster, boosted) |> repo().insert()
  end

  defp changeset(booster, boosted) do
    Boost.changeset(%Boost{}, %{booster_id: ulid(booster), boosted_id: ulid(boosted)})
  end

  #doc "Delete boosts where i am the booster"
  defp delete_by_booster(%{}=subject), do: query([subject: subject], skip_boundary_check: true) |> do_delete()

  #doc "Delete boosts where i am the boosted"
  defp delete_by_boosted(%{}=object), do: query([object: object], skip_boundary_check: true) |> do_delete()

  #doc "Delete boosts where i am the booster or the boosted."
  # defp delete_by_any(%{}=me), do: elem(repo().delete_all(by_any_q(me)), 1)

  #doc "Delete boosts where i am the booster and someone else is the boosted."
  defp delete_by_both(me, object), do: [subject: me, object: object] |> query(skip_boundary_check: true) |> do_delete()

  defp do_delete(q), do: Ecto.Query.exclude(q, :preload) |> repo().delete_all() |> elem(1)


  def ap_publish_activity("create", boost) do
    boost = Bonfire.Repo.preload(boost, :boosted)

    with {:ok, booster} <- ActivityPub.Actor.get_cached_by_local_id(boost.booster_id),
         boosted when not is_nil(boosted) <- Bonfire.Common.Pointers.follow!(boost.boosted),
         object when not is_nil(boosted) <- Bonfire.Federate.ActivityPub.Utils.get_object(boosted) do
            ActivityPub.announce(booster, object)
    end
  end

  def ap_publish_activity("delete", boost) do
    boost = Bonfire.Repo.preload(boost, :boosted)

    with {:ok, booster} <- ActivityPub.Actor.get_cached_by_local_id(boost.booster_id),
         boosted when not is_nil(boosted) <- Bonfire.Common.Pointers.follow!(boost.boosted),
         object when not is_nil(boosted) <- Bonfire.Federate.ActivityPub.Utils.get_object(boosted) do
            ActivityPub.unannounce(booster, object)
    end
  end

  def ap_receive_activity(creator, %{data: %{"type" => "Announce"}} = _activity, object) do
    with {:ok, boosted} <- Bonfire.Common.Pointers.get(object.pointer_id, current_user: creator) do
           boost(creator, boosted)
    end
  end

  def ap_receive_activity(creator, %{data: %{"type" => "Undo"}} = _activity, %{data: %{"object" => boosted_object}} = _object) do
    with object when not is_nil(object) <- ActivityPub.Object.get_cached_by_ap_id(boosted_object),
         {:ok, boosted} <- Bonfire.Common.Pointers.get(object.pointer_id, current_user: creator),
         [id] <- unboost(creator, boosted) do
          {:ok, id}
    end
  end
end
