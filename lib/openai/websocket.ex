defmodule MembraneOpenAI.OpenAIWebSocket do
  use WebSockex
  require Logger

  def start_link(opts) do
    WebSockex.start_link(
      "wss://api.openai.com/v1/realtime?model=gpt-realtime",
      __MODULE__,
      %{parent: self()},
      opts
    )
  end

  @impl true
  def handle_connect(_conn, state) do
    # way to sent a frame to websocket from inside the handle_connect, sending through send_frame(self(), frame) will not work
    # WebSockex.cast(self(), :send_frame)

    {:ok, state}
  end

  # def handle_cast(:send_frame, state) do
  # session_update =
  #   %{
  #   }

  # frame =
  #   Jason.encode!(session_update)

  # {:reply, {:text, frame}, state}
  # end

  @impl true
  def handle_frame(frame, state) do
    send(state.parent, {:websocket_frame, frame})
    {:ok, state}
  end

  def send_frame(ws, frame) do
    WebSockex.send_frame(ws, {:text, frame})
  end
end
