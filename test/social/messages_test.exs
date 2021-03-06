defmodule Bonfire.Social.MessagesTest do
  use Bonfire.DataCase

  alias Bonfire.Social.{Messages, Feeds, FeedActivities}
  alias Bonfire.Me.Fake
  import Where

  test "can message a user" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    msg = "hey receiver, you have an epic text message"
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: msg}}
    assert {:ok, message} = Messages.send(sender, attrs)

    assert message.post_content.html_body =~ msg
  end

  test "can list messages I sent" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert %{edges: [fp]} = Messages.list(sender)
    assert fp.id == message.id
  end


  test "can list messages I sent to a specific person" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()

    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert %{edges: feed} = Messages.list(sender, receiver)
    assert List.first(feed).id == message.id
  end

  test "can list messages sent to me" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()

    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert %{edges: feed} = Messages.list(receiver)
    assert List.first(feed).id == message.id
  end

  test "can list messages sent to me by a specific person" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()

    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    assert %{edges: feed} = Messages.list(receiver, sender)
    assert List.first(feed).id == message.id
  end

  test "random person CANNOT list messages I sent to another person" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    other = Fake.fake_user!()

    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    refute match? %{edges: [_]}, Messages.list(other)
    refute match? %{edges: [_]}, Messages.list(sender, other)
    refute match? %{edges: [_]}, Messages.list(other, sender)
  end

  # broken because we filter messages out of feeds and use Messages.list instead
  # test "messages addressed to me appear in my inbox feed" do
  #   sender = Fake.fake_user!()
  #   receiver = Fake.fake_user!()
  #   attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

  #   assert {:ok, m} = Messages.send(sender, attrs)

  #   assert %{edges: [fp]} = FeedActivities.feed(:inbox, receiver)
  #   assert fp.activity.id == m.activity.id
  # end

  test "messaging someone does NOT appear in my own inbox feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    refute match? %{edges: [_]}, FeedActivities.feed(:inbox, sender)
  end

  test "messaging someone else does NOT appear in a 3rd party's inbox" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    third = Fake.fake_user!()

    refute match? %{edges: [_]}, FeedActivities.feed(:inbox, third)
  end

  test "messaging someone does NOT appear in their feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    refute match? %{edges: [_]}, FeedActivities.my_feed(receiver)
  end

  test "messaging someone does NOT appear in their instance feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

    refute match? %{edges: [_]}, FeedActivities.feed(feed_id, receiver)

  end

  test "messaging someone does NOT appear in my instance feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

    refute match? %{edges: [_]}, FeedActivities.feed(feed_id, sender)

  end

  test "messaging someone does NOT appear in a 3rd party's instance feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    third = Fake.fake_user!()

    feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

    refute match? %{edges: [_]}, FeedActivities.feed(feed_id, third)
  end

  test "messaging someone does NOT appear in the public instance feed" do
    sender = Fake.fake_user!()
    receiver = Fake.fake_user!()
    attrs = %{to_circles: [receiver.id], post_content: %{html_body: "<p>hey receiver, you have an epic html message</p>"}}

    assert {:ok, message} = Messages.send(sender, attrs)

    feed_id = Bonfire.Social.Feeds.named_feed_id(:local)

    refute match? %{edges: [_]}, FeedActivities.feed(feed_id, nil)
  end


end
