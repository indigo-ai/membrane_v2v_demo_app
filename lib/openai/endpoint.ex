defmodule MembraneOpenAI.OpenAIEndpoint do
  @moduledoc """
  An element that handles communication with the OpenAI Whisper/TTS API via a WebSocket,
  buffers the incoming response audio, and pushes it downstream at a configurable pace.
  """
  use Membrane.Filter
  require Membrane.Logger

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any, flow_control: :push)

  def_options(websocket_opts: [])

  # time in nanoseconds -> 100 millis
  @interval 200_000_000

  @impl true
  def handle_init(_ctx, opts) do
    {:ok, ws} = MembraneOpenAI.OpenAIWebSocket.start_link(opts.websocket_opts)

    state = %{
      ws: ws,
      queue: :queue.new(),
      transcript_logs: [],
      timer_status: nil
    }

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    # Standard format for OpenAI voice streaming, the audio sent to openai
    Membrane.Logger.debug("[OpenAi] Starting audio streaming and setting format.")
    format = %Membrane.RawAudio{channels: 1, sample_rate: 24_000, sample_format: :s16le}
    {[stream_format: {:output, format}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    # This pad receives user audio input, which is immediately forwarded to the WebSocket.
    audio = Base.encode64(buffer.payload)
    frame = %{type: "input_audio_buffer.append", audio: audio} |> Jason.encode!()

    :ok =
      MembraneOpenAI.OpenAIWebSocket.send_frame(state.ws, frame)

    {[], state}
  end

  # Timer that sends buffer to output pad
  @impl true
  def handle_tick(:pacer, _ctx, state) do
    Membrane.Logger.debug(
      "[OpenAi] Calling handle_tick, #{:queue.len(state.queue)}, timer status: #{state.timer_status}"
    )

    case :queue.out(state.queue) do
      {:empty, _queue} ->
        # Queue is empty, stop the timer until new audio arrives
        Membrane.Logger.debug("[OpenAi] Pacing done, queue empty. Stopping timer.")
        {[stop_timer: :pacer], %{state | timer_status: nil}}

      {{:value, buffer_to_send}, rest_of_queue} ->
        # Found a buffer, send it downstream
        actions = [buffer: {:output, buffer_to_send}]

        Membrane.Logger.debug("[OpenAi] Sending buffer")
        # More buffers remain, restart the timer for the next interval
        {
          actions ++
            [],
          %{
            state
            | queue: rest_of_queue
          }
        }
    end
  end

  @impl true
  def handle_info({:websocket_frame, {:text, frame}}, _ctx, state) do
    case Jason.decode!(frame) do
      %{"type" => "session.created"} ->
        session_update =
          %{
            "type" => "session.update",
            "session" => %{
              "input_audio_transcription" => %{
                "model" => "whisper-1"
              },
              "instructions" => """
              You are a helpful junior customer service agent. Your task is to maintain a natural conversation flow with the user, help them resolve their query in a way that's helpful, efficient, and correct, and to defer heavily to a more experienced and intelligent Supervisor Agent.

              # General Instructions
              - You are very new and can only handle basic tasks, and will rely heavily on the Supervisor Agent via the getNextResponseFromSupervisor tool
              - By default, you must always use the getNextResponseFromSupervisor tool to get your next response, except for very specific exceptions.
              - You represent a company called 'Indigo.ai'.
              - Always greet the user with "Hi, you've reached 'Indigo.ai', how can I help you?"
              - If the user says "hi", "hello", or similar greetings in later messages, respond naturally and briefly (e.g., "Hello!" or "Hi there!") instead of repeating the canned greeting.
              - In general, don't say the same thing twice, always vary it to ensure the conversation feels natural.
              - Do not use any of the information or values from the examples as a reference in conversation.

              ## Tone
              - Maintain an extremely neutral, unexpressive, and to-the-point tone at all times.
              - Do not use sing-song-y or overly friendly language
              - Be quick and concise

              # Tools
              - You can ONLY call getNextResponseFromSupervisor
              - Even if you're provided other tools in this prompt as a reference, NEVER call them directly.

              # Allow List of Permitted Actions
              You can take the following actions directly, and don't need to use getNextResponse for these.

              ## Basic chitchat
              - Handle greetings (e.g., "hello", "hi there").
              - Engage in basic chitchat (e.g., "how are you?", "thank you").
              - Respond to requests to repeat or clarify information (e.g., "can you repeat that?").

              ## Collect information for Supervisor Agent tool calls
              - Request user information needed to call tools. Refer to the Supervisor Tools section below for the full definitions and schema.

              ### Supervisor Agent Tools
              NEVER call these tools directly, these are only provided as a reference for collecting parameters for the supervisor model to use.

              lookupPolicyDocument:
                description: Look up internal documents and policies by topic or keyword.
                params:
                  topic: string (required) - The topic or keyword to search for.

              getUserAccountInfo:
                description: Get user account and billing information (read-only).
                params:
                  phone_number: string (required) - User's phone number.

              findNearestStore:
                description: Find the nearest store location given a zip code.
                params:
                  zip_code: string (required) - The customer's 5-digit zip code.

              **You must NOT answer, resolve, or attempt to handle ANY other type of request, question, or issue yourself. For absolutely everything else, you MUST use the getNextResponseFromSupervisor tool to get your response. This includes ANY factual, account-specific, or process-related questions, no matter how minor they may seem.**

              # getNextResponseFromSupervisor Usage
              - For ALL requests that are not strictly and explicitly listed above, you MUST ALWAYS use the getNextResponseFromSupervisor tool, which will ask the supervisor Agent for a high-quality response you can use.
              - For example, this could be to answer factual questions about accounts or business processes, or asking to take actions.
              - Do NOT attempt to answer, resolve, or speculate on any other requests, even if you think you know the answer or it seems simple.
              - You should make NO assumptions about what you can or can't do. Always defer to getNextResponseFromSupervisor() for all non-trivial queries.
              - Before calling getNextResponseFromSupervisor, you MUST ALWAYS say something to the user (see the 'Sample Filler Phrases' section). Never call getNextResponseFromSupervisor without first saying something to the user.
                - Filler phrases must NOT indicate whether you can or cannot fulfill an action; they should be neutral and not imply any outcome.
                - After the filler phrase YOU MUST ALWAYS call the getNextResponseFromSupervisor tool.
                - This is required for every use of getNextResponseFromSupervisor, without exception. Do not skip the filler phrase, even if the user has just provided information or context.
              - You will use this tool extensively.

              ## How getNextResponseFromSupervisor Works
              - This asks supervisorAgent what to do next. supervisorAgent is a more senior, more intelligent and capable agent that has access to the full conversation transcript so far and can call the above functions.
              - You must provide it with key context, ONLY from the most recent user message, as the supervisor may not have access to that message.
                - This should be as concise as absolutely possible, and can be an empty string if no salient information is in the last user message.
              - That agent then analyzes the transcript, potentially calls functions to formulate an answer, and then provides a high-quality answer, which you should read verbatim

              # Sample Filler Phrases
              - "Just a second."
              - "Let me check."
              - "One moment."
              - "Let me look into that."
              - "Give me a moment."
              - "Let me see."

              # Example
              - User: "Hi"
              - Assistant: "Hi, you've reached 'Indigo.ai', how can I help you?"
              - User: "I'm wondering why my recent bill was so high"
              - Assistant: "Sure, may I have your phone number so I can look that up?"
              - User: 206 135 1246
              - Assistant: "Okay, let me look into that" // Required filler phrase
              - getNextResponseFromSupervisor(relevantContextFromLastUserMessage="Phone number: 206 123 1246)
                - getNextResponseFromSupervisor(): "# Message\nOkay, I've pulled that up. Your last bill was $xx.xx, mainly due to $y.yy in international calls and $z.zz in data overage. Does that make sense?"
              - Assistant: "Okay, I've pulled that up. It looks like your last bill was $xx.xx, which is higher than your usual amount because of $x.xx in international calls and $x.xx in data overage charges. Does that make sense?"
              - User: "Okay, yes, thank you."
              - Assistant: "Of course, please let me know if I can help with anything else."
              - User: "Actually, I'm wondering if my address is up to date, what address do you have on file?"
              - Assistant: "1234 Pine St. in Seattle, is that your latest?"
              - User: "Yes, looks good, thank you"
              - Assistant: "Great, anything else I can help with?"
              - User: "Nope that's great, bye!"
              - Assistant: "Of course, thanks for calling 'Indigo.ai'!"

              # Additional Example (Filler Phrase Before getNextResponseFromSupervisor)
              - User: "Can you tell me what my current plan includes?"
              - Assistant: "One moment."
              - getNextResponseFromSupervisor(relevantContextFromLastUserMessage="Wants to know what their current plan includes")
                - getNextResponseFromSupervisor(): "# Message\nYour current plan includes unlimited talk and text, plus 10GB of data per month. Would you like more details or information about upgrading?"
              - Assistant: "Your current plan includes unlimited talk and text, plus 10GB of data per month. Would you like more details or information about upgrading?
              """,
              "tools" => [
                %{
                  "type" => "function",
                  "name" => "getNextResponseFromSupervisor",
                  "description" =>
                    "Determines the next response whenever the agent faces a non-trivial decision, produced by a highly intelligent supervisor agent. Returns a message describing what to do next.",
                  "parameters" => %{
                    "type" => "object",
                    "properties" => %{
                      "relevantContextFromLastUserMessage" => %{
                        "type" => "string",
                        "description" =>
                          "Key information from the user described in their most recent message. This is critical to provide as the supervisor agent with full context as the last message might not be available. Okay to omit if the user message didn't add any new information."
                      }
                    },
                    "additionalProperties" => false
                  }
                }
              ]
            }
          }

        frame =
          Jason.encode!(session_update)

        MembraneOpenAI.OpenAIWebSocket.send_frame(state.ws, frame)

        {[], state}

      %{"type" => "error"} = response ->
        Membrane.Logger.warning("[OpenAi]: #{inspect(response)}")
        {[], state}

      %{"type" => "session.updated"} = response ->
        Membrane.Logger.debug("[OpenAi] Session Updated: #{inspect(response)}")
        {[], state}

      %{
        "type" => "conversation.item.input_audio_transcription.completed",
        "response" => %{
          "transcript" => user_message
        }
      } ->
        Membrane.Logger.debug("[OpenAi] user message: #{inspect(user_message)}")

        {[],
         %{
           state
           | transcript_logs: [%{role: "user", content: user_message} | state.transcript_logs]
         }}

      %{
        "type" => "response.done",
        "response" => %{
          "output" => [
            _content,
            %{
              "type" => "function_call",
              "name" => "getNextResponseFromSupervisor",
              "call_id" => call_id,
              "id" => id,
              "arguments" => arguments
            } = tool_call
          ]
        }
      } ->
        {:ok,
         %{
           "relevantContextFromLastUserMessage" => relevant_context_from_last_user_message
         }} = Jason.decode(arguments)

        call_get_next_response_from_supervisor(%{
          relevant_context_from_last_user_message: relevant_context_from_last_user_message,
          transcript_logs: state.transcript_logs |> Enum.reverse(),
          call_id: call_id,
          id: id,
          state: state
        })

        Membrane.Logger.debug("[OpenAi] Tool Call response.done: #{inspect(tool_call)}")

        {[], state}

      %{
        "type" => "response.done",
        "response" => %{
          "output" => output
        }
      } ->
        Membrane.Logger.debug("[OpenAi] generic response.done: #{inspect(output)}")

        {[], state}

      %{"type" => "input_audio_buffer.speech_started"} ->
        Membrane.Logger.debug("[OpenAi] Barge in")

        # Cancel the current response from OpenAI and reset internal buffer queue
        frame = %{type: "response.cancel"} |> Jason.encode!()
        :ok = MembraneOpenAI.OpenAIWebSocket.send_frame(state.ws, frame)

        timer_is_running = !is_nil(state.timer_status)

        actions =
          if timer_is_running do
            Membrane.Logger.debug("[OpenAi] stopping timer")
            [stop_timer: :pacer]
          else
            []
          end

        {actions, %{state | queue: :queue.new(), timer_status: nil}}

      %{"type" => "response.audio.delta", "delta" => delta} ->
        Membrane.Logger.debug("[OpenAi] Receiving response delta and enqueueing buffer")
        audio_payload = Base.decode64!(delta)
        buffer = %Membrane.Buffer{payload: audio_payload}
        new_queue = :queue.in(buffer, state.queue)

        should_start_timer = is_nil(state.timer_status)

        # Determine the new state
        new_state =
          if should_start_timer do
            %{
              state
              | timer_status: :running,
                queue: new_queue
            }
          else
            %{state | queue: new_queue}
          end

        # Determine actions related to pacing
        pacer_actions =
          if should_start_timer do
            [
              start_timer: {
                :pacer,
                @interval
              }
            ]
          else
            []
          end

        Membrane.Logger.debug(
          "[OpenAi] response.audio.delta: should_start_timer: #{should_start_timer}"
        )

        {pacer_actions, new_state}

      %{"type" => "response.audio.done"} ->
        # The stream is complete, nothing more to enqueue. The timer will stop when the queue empties.
        Membrane.Logger.debug("[OpenAi] Response audio stream ended.")

        {[], state}

      %{"type" => "response.audio_transcript.done", "transcript" => transcript} ->
        Membrane.Logger.debug("[OpenAi] AI transcription: #{transcript}")

        {[],
         %{
           state
           | transcript_logs: [%{role: "assistant", content: transcript} | state.transcript_logs]
         }}

      %{} ->
        Membrane.Logger.debug("[OpenAi] Unhandled WS frame: #{frame}")
        {[], state}
    end
  end

  def call_get_next_response_from_supervisor(
        %{
          relevant_context_from_last_user_message: relevant_context_from_last_user_message,
          transcript_logs: transcript_logs,
          call_id: call_id,
          # id: id,
          state: state
        } = tool_calling
      ) do
    Membrane.Logger.debug(
      "[OpenAi] call_get_next_response_from_supervisor: #{inspect(tool_calling)}"
    )

    # Prepare the request data according to the curl example
    request_data = %{
      "target" => "mother_agent",
      "data" => %{
        "relevantContextFromLastUserMessage" => relevant_context_from_last_user_message,
        "transcriptLogs" =>
          Jason.encode!(%{
            "relevantContextFromLastUserMessage" => relevant_context_from_last_user_message,
            "transcriptLogs" => transcript_logs
          })
      },
      "last_user_message" => relevant_context_from_last_user_message
    }

    # Make HTTP POST request to the external service
    url = "http://localhost:4001/rest/trigger/sync/f1f18a18-ea8a-481b-a3f0-9c6dbd8b0d4f"

    case Req.post(url,
           json: request_data,
           headers: [
             {"Authorization",
              "Bearer pat-624d156c-168e-47f0-8fcc-95c2343460e15eb7f30e-28eb-4363-b9e7-cf18d47f802d"}
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Membrane.Logger.debug("[OpenAi] Supervisor response: #{inspect(body)}")

        # Parse the response and create the function call output
        response = %{
          "type" => "conversation.item.create",
          "item" => %{
            "type" => "function_call_output",
            "call_id" => call_id,
            "output" => Jason.encode!(body)
          }
        }

        frame = Jason.encode!(response)
        MembraneOpenAI.OpenAIWebSocket.send_frame(state.ws, frame)

        # Trigger response creation
        MembraneOpenAI.OpenAIWebSocket.send_frame(
          state.ws,
          Jason.encode!(%{
            "type" => "response.create"
          })
        )

      {:ok, %Req.Response{status: status_code, body: body}} ->
        Membrane.Logger.error(
          "[OpenAi] Supervisor request failed with status #{status_code}: #{inspect(body)}"
        )

        # Send error response
        error_response = %{
          "type" => "conversation.item.create",
          "item" => %{
            "type" => "function_call_output",
            "call_id" => call_id,
            "output" => "{\"error\": \"Supervisor service unavailable\"}"
          }
        }

        frame = Jason.encode!(error_response)
        MembraneOpenAI.OpenAIWebSocket.send_frame(state.ws, frame)

        MembraneOpenAI.OpenAIWebSocket.send_frame(
          state.ws,
          Jason.encode!(%{
            "type" => "response.create"
          })
        )

      {:error, reason} ->
        Membrane.Logger.error("[OpenAi] Supervisor request failed: #{inspect(reason)}")

        # Send error response
        error_response = %{
          "type" => "conversation.item.create",
          "item" => %{
            "type" => "function_call_output",
            "call_id" => call_id,
            "output" => "{\"error\": \"Supervisor service unavailable\"}"
          }
        }

        frame = Jason.encode!(error_response)
        MembraneOpenAI.OpenAIWebSocket.send_frame(state.ws, frame)

        MembraneOpenAI.OpenAIWebSocket.send_frame(
          state.ws,
          Jason.encode!(%{
            "type" => "response.create"
          })
        )
    end
  end
end
