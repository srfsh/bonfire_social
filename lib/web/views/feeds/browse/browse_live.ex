defmodule Bonfire.Social.Web.Feeds.BrowseLive do
  use Bonfire.Web, :surface_view
  alias Bonfire.Web.LivePlugs

  def mount(params, session, socket) do
    LivePlugs.live_plug params, session, socket, [
      LivePlugs.LoadCurrentAccount,
      LivePlugs.LoadCurrentUser,
      LivePlugs.LoadCurrentUserCircles,
      # LivePlugs.LoadCurrentAccountUsers,
      LivePlugs.StaticChanged,
      LivePlugs.Csrf, LivePlugs.Locale,
      &mounted/3,
    ]
  end

  defp mounted(_params, _session, socket) do

    # feed = Bonfire.Social.FeedActivities.my_feed(socket)

    {:ok, socket
    |> assign(
      page: "browse",
      page_title: "Browse",
      selected_tab: "feed",
      smart_input: true,
      has_private_tab: false,
      feed_title: "Browse",
      feed: [],
      page_info: []
      )}
  end

  # WIP: Commented this as it was call anytime the user clicked on a different tab, preventing to load the right feed
  # def handle_params(_attrs, _, %{assigns: %{feed: feed, page_info: pi}} = socket) when is_list(feed) and pi !=[] do
  #   debug("we already have a feed loaded")
  #   {:noreply, socket}
  # end

  def do_handle_params(%{"tab" => "fediverse" = tab} = _params, _url, socket) do
    current_user = current_user(socket)

    assigns = if current_user || current_account(socket) do

      fediverse_feed(socket)
    else
      []
    end

    {:noreply, assign(socket, assigns)}
  end

  def do_handle_params(%{"tab" => "instance" = tab} = _params, _url, socket) do
    current_user = current_user(socket)

    {:noreply, assign(socket, instance_feed(socket)) }
  end

  def do_handle_params(_params, _url, socket) do

    {:noreply, assign(socket, default_feed(socket))}
  end

  def default_feed(socket) do
    current_user = current_user(socket)
    current_account = current_account(socket)

    current = current_user || current_account

    if current do
      my_feed(current, socket) # my feed
    else
      instance_feed(socket) # fallback to showing instance feed
    end
  end

  def fediverse_feed(socket) do
    feed_id = Bonfire.Social.Feeds.named_feed_id(:activity_pub)
    feed = Bonfire.Social.FeedActivities.feed(feed_id, socket)

    [
      current_user: current_user(socket),
      selected_tab: "fediverse",
      feed_title: "Activities from around the fediverse",
      feed_id: feed_id,
      feed: e(feed, :edges, []),
      page_info: e(feed, :page_info, []),
    ]
  end

  def instance_feed(socket) do
    feed_id = Bonfire.Social.Feeds.named_feed_id(:local)
    feed = Bonfire.Social.FeedActivities.feed(feed_id, socket)

    [
      current_user: current_user(socket),
      selected_tab: "instance",
      feed_title: "Activities on this instance",
      feed_id: feed_id,
      feed: e(feed, :edges, []),
      page_info: e(feed, :page_info, []) #|> IO.inspect
    ]
  end

  def my_feed(current_user, socket) do
    # debug(myfeed: feed)
    feed = Bonfire.Social.FeedActivities.my_feed(socket)
    [
      current_user: current_user,
      selected_tab: "feed",
      feed_title: "My Feed",
      feed_id: "my:"<>e(current_user, :id, ""),
      feed: e(feed, :edges, []),
      page_info: e(feed, :page_info, [])
    ]
  end


  def handle_params(params, uri, socket) do
    # poor man's hook I guess
    with {_, socket} <- Bonfire.Common.LiveHandlers.handle_params(params, uri, socket) do
      undead_params(socket, fn ->
        do_handle_params(params, uri, socket)
      end)
    end
  end

  def handle_event(action, attrs, socket), do: Bonfire.Common.LiveHandlers.handle_event(action, attrs, socket, __MODULE__)
  def handle_info(info, socket), do: Bonfire.Common.LiveHandlers.handle_info(info, socket, __MODULE__)

end
