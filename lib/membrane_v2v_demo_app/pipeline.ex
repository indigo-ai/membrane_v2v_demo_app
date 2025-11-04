defmodule MembraneV2vDemoApp.Call.Pipeline do
  use Membrane.Pipeline

  def start_link(opts) do
    Membrane.Pipeline.start_link(__MODULE__, opts)
  end

  def do_handle_info(value, rest) do
    IO.inspect(value, label: "HANDLE INFO VALUE")
    IO.inspect(rest, label: "HANDLE INFO REST")
  end

  def handle_terminate_request(pipeline_pid, _) do
    Membrane.Pipeline.terminate(pipeline_pid)
  end

  @impl true
  def handle_init(_ctx, opts) do
    require Membrane.Logger

    # pipeline_pid = self()

    spec = build_openai_spec(opts)

    Membrane.Logger.info("Pipeline spec created with #{length(spec)} elements")

    {[spec: spec], %{}}
  end

  defp build_openai_spec(opts) do
    openai_api_key = Application.get_env(:membrane_v2v_demo_app, :openai_api_key)

    openai_ws_opts = [
      extra_headers: [
        {"Authorization", "Bearer " <> openai_api_key},
        {"OpenAI-Beta", "realtime=v1"}
      ]
    ]

    [
      # Input path: Mic → OpenAI
      child(:webrtc_source, %Membrane.WebRTC.Source{
        signaling: opts[:source_channel]
      })
      |> via_out(:output, options: [kind: :audio])
      |> child(:input_opus_parser, Membrane.Opus.Parser)
      |> child(:opus_decoder, %Membrane.Opus.Decoder{sample_rate: 24_000})

      # Output path: OpenAI → Browser
      |> child(:open_ai, %MembraneOpenAI.OpenAIEndpoint{
        websocket_opts: openai_ws_opts,
        sender_id: opts[:sender_id]
      })
      |> child(:raw_audio_parser, %Membrane.RawAudioParser{overwrite_pts?: true})
      |> child(:opus_encoder, Membrane.Opus.Encoder)
      |> via_in(:input, options: [kind: :audio])
      |> child(:webrtc_sink, %Membrane.WebRTC.Sink{
        tracks: [:audio],
        signaling: opts[:sink_channel]
      })
    ]
  end
end
