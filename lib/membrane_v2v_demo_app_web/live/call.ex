defmodule MembraneV2vDemoAppWeb.CallLive do
  use MembraneV2vDemoAppWeb, :live_view

  alias Membrane
  alias WebRTC
  alias MembraneV2vDemoApp.Call.Pipeline

  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        ingress_signaling = Membrane.WebRTC.Signaling.new()
        egress_signaling = Membrane.WebRTC.Signaling.new()

        socket
        |> assign(:ingress_signaling, ingress_signaling)
        |> assign(:egress_signaling, egress_signaling)
        |> assign(:is_call_active, false)
        |> assign(:pipeline_pid, nil)
        |> Membrane.WebRTC.Live.Capture.attach(
          id: "mediaCapture",
          signaling: ingress_signaling,
          video?: false,
          audio?: true,
          preview?: false
        )
        |> Membrane.WebRTC.Live.Player.attach(
          id: "audioPlayer",
          signaling: egress_signaling
        )
      else
        socket
        |> assign(:ingress_signaling, nil)
        |> assign(:egress_signaling, nil)
        |> assign(:is_call_active, false)
        |> assign(:pipeline_pid, nil)
      end

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center min-h-screen bg-gray-100">
      <div class="bg-white p-8 rounded-lg shadow-lg">
        <h1 class="text-2xl font-bold text-center mb-8">Voice Call Interface</h1>

        <div class="flex justify-center mb-8">
          <button
            phx-click="toggle_call"
            class={[
              "px-8 py-4 rounded-lg font-semibold text-lg transition-colors",
              if(@is_call_active, do: "bg-red-500 hover:bg-red-600 text-white", else: "bg-green-500 hover:bg-green-600 text-white")
            ]}
          >
            {if @is_call_active, do: "End Call", else: "Start Call"}
          </button>
        </div>

        <div class="text-center text-sm text-gray-600">
          <p>Call Status: <span class={if @is_call_active, do: "text-green-600 font-semibold", else: "text-gray-500"}>
            {if @is_call_active, do: "Active", else: "Inactive"}
          </span></p>
        </div>
      </div>
    </div>

    <style>
    #mediaCapture {
      display: none !important;
    }
    </style>
    <Membrane.WebRTC.Live.Capture.live_render socket={@socket} capture_id="mediaCapture" />
    <Membrane.WebRTC.Live.Player.live_render socket={@socket} player_id="audioPlayer" />
    """
  end

  def handle_event("toggle_call", _params, socket) do
    if socket.assigns.is_call_active do
      stop_call(socket)
    else
      start_call(socket)
    end
  end

  defp start_call(socket) do
    if socket.assigns.ingress_signaling && socket.assigns.egress_signaling do
      # Start the pipeline
      {:ok, _, pipeline_pid} =
        Membrane.Pipeline.start_link(Pipeline,
          source_channel: socket.assigns.ingress_signaling,
          sink_channel: socket.assigns.egress_signaling
        )

      # Start capture and player
      # Membrane.WebRTC.Live.Capture.start(socket, "mediaCapture")
      # Membrane.WebRTC.Live.Player.start(socket, "audioPlayer")

      {:noreply,
       socket
       |> assign(:is_call_active, true)
       |> assign(:pipeline_pid, pipeline_pid)}
    else
      {:noreply, socket}
    end
  end

  defp stop_call(socket) do
    if socket.assigns.ingress_signaling && socket.assigns.egress_signaling do
      # Stop capture and player
      # Membrane.WebRTC.Live.Capture.stop(socket, "mediaCapture")
      # Membrane.WebRTC.Live.Player.stop(socket, "audioPlayer")
      socket.assigns.pipeline_pid
      |> IO.inspect(label: "socket.assigns.pipeline_pid")

      # Stop the pipeline
      if socket.assigns.pipeline_pid do
        # GenServer.stop(socket.assigns.pipeline_pid)
        Membrane.Pipeline.terminate(
          Pento.Call.Pipeline
          # pipeline: socket.assigns.pipeline_pid,
          # force?: true
        )
        |> IO.inspect(label: "TERMINATE")
      end

      {:noreply,
       socket
       |> assign(:is_call_active, false)
       |> assign(:pipeline_pid, nil)}
    else
      {:noreply, socket}
    end
  end
end
