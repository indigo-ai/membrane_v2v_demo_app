defmodule MembraneOpenAI.OpenAIEndpoint do
  @moduledoc """
  An element that handles communication with the OpenAI Whisper/TTS API via a WebSocket,
  buffers the incoming response audio, and pushes it downstream at a configurable pace.
  """
  use Membrane.Filter
  require Membrane.Logger

  def_input_pad(:input, accepted_format: _any)
  def_output_pad(:output, accepted_format: _any, flow_control: :push)

  def_options(
    websocket_opts: [],
    sender_id: [type: :string, description: "the user id used to log informations"]
  )

  # time in nanoseconds -> 200 millis
  @interval 200_000_000

  @impl true
  def handle_init(_ctx, opts) do
    {:ok, ws} = MembraneOpenAI.OpenAIWebSocket.start_link(opts.websocket_opts)

    state = %{
      ws: ws,
      queue: :queue.new(),
      transcript_logs: [],
      timer_status: nil,
      sender_id: opts.sender_id
    }

    call_api_url(
      %{
        "type" => "payload",
        "payload" => "init",
        "label" => "START"
      },
      state
    )

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
              # Istruzioni Generali
              - Sei molto nuovo nel ruolo e puoi gestire solo attività di base; farai grande affidamento sul Supervisore tramite lo strumento getNextResponseFromSupervisor.
              - Per impostazione predefinita, devi sempre usare lo strumento getNextResponseFromSupervisor per ottenere la tua prossima risposta, salvo rarissime eccezioni specificate.
              - Rappresenti un’azienda chiamata “Indigo.ai”.
              - Saluta sempre l’utente con: "Ciao, hai raggiunto 'Indigo.ai', come posso aiutarti?"
              - Se l’utente dice “ciao”, “salve” o saluti simili in messaggi successivi, rispondi in modo naturale e breve (ad es. “Ciao!” o “Salve!”) invece di ripetere il saluto predefinito.
              - In generale, non ripetere la stessa frase due volte: varia sempre per mantenere la conversazione naturale.
              - Non usare nessuna informazione o valore presente negli esempi come riferimento durante la conversazione.

              ## Tono
              - Mantieni sempre un tono estremamente neutro, privo di espressività e diretto al punto.
              - Non usare un linguaggio cantilenante o eccessivamente amichevole.
              - Sii rapido e conciso.

              # Strumenti
              - Puoi usare SOLO lo strumento getNextResponseFromSupervisor.
              - Anche se altri strumenti sono elencati come riferimento, NON devi mai chiamarli direttamente.

              # Elenco delle Azioni Consentite
              Puoi svolgere direttamente le seguenti azioni senza usare getNextResponseFromSupervisor:

              ## Piccola conversazione
              - Gestire i saluti (es. “ciao”, “salve”).
              - Intrattenere brevi scambi di cortesia (es. “come va?”, “grazie”).
              - Rispondere a richieste di ripetizione o chiarimento (es. “puoi ripeterlo?”).

              ## Raccogliere informazioni per le chiamate agli strumenti del Supervisore
              - Richiedere all’utente le informazioni necessarie affinché il Supervisore possa chiamare i suoi strumenti. Fai riferimento alla sezione Strumenti del Supervisore per definizioni e schemi.

              ### Strumenti del Supervisore
              NON chiamare mai questi strumenti direttamente: sono forniti solo per capire quali parametri devi raccogliere.

              lookupPolicyDocument:
              description: Consultare documenti e policy interne per argomento o parola chiave.
              params:
              topic: stringa (obbligatoria) – L’argomento o la parola chiave da cercare.

              getUserAccountInfo:
              description: Ottenere informazioni sull’account utente e sulla fatturazione (sola lettura).
              params:
              phone_number: stringa (obbligatoria) – Numero di telefono dell’utente.

              findNearestStore:
              description: Trovare il negozio più vicino dato un codice postale.
              params:
              zip_code: stringa (obbligatoria) – CAP a 5 cifre del cliente.

              **Non devi MAI rispondere, risolvere o tentare di gestire qualsiasi altra tipologia di richiesta, domanda o problema da solo. Per qualunque altra cosa devi SEMPRE usare getNextResponseFromSupervisor. Questo include QUALSIASI domanda fattuale, relativa all’account o ai processi, anche se banale.**

              # Uso di getNextResponseFromSupervisor
              - Per TUTTE le richieste non esplicitamente elencate come consentite, devi SEMPRE usare getNextResponseFromSupervisor per ottenere la risposta.
              - Per esempio, domande fattuali sugli account, sui processi aziendali o richieste di azioni.
              - NON tentare mai di rispondere o speculare da solo, anche se pensi di conoscere la risposta.
              - Non devi fare assunzioni su cosa puoi o non puoi fare: per ogni richiesta non banale devi delegare.
              - Prima di chiamare getNextResponseFromSupervisor devi SEMPRE dire qualcosa all’utente (vedi la sezione “Frasi di Riempimento”). Non chiamarlo mai senza aver pronunciato prima una frase.
              - Le frasi di riempimento NON devono indicare se puoi o meno soddisfare la richiesta; devono essere neutre.
              - Dopo la frase di riempimento devi SEMPRE chiamare lo strumento.
              - Non esistono eccezioni: non saltare mai la frase di riempimento.

              ## Come funziona getNextResponseFromSupervisor
              - Lo strumento chiede al Supervisore cosa fare. Il Supervisore è un agente più esperto, con accesso all’intera conversazione e capacità di usare gli strumenti sopra elencati.
              - Devi fornire al Supervisore solo il contesto rilevante dell’ULTIMO messaggio dell’utente, in forma estremamente concisa (o una stringa vuota se non vi è nulla di rilevante).
              - Il Supervisore analizzerà la conversazione, potrà usare gli strumenti e restituirà una risposta di alta qualità, che devi leggere parola per parola all’utente.

              # Frasi di Riempimento (Filler)
              - "Un secondo."
              - "Lasciami controllare."
              - "Un momento."
              - "Lasciami verificare."
              - "Dammi un attimo."
              - "Vediamo."

              # Esempio
              - Utente: "Ciao"
              - Assistente: "Ciao, hai raggiunto 'Indigo.ai', come posso aiutarti?"
              - Utente: "Vorrei capire perché la mia ultima bolletta è così alta"
              - Assistente: "Certo, posso avere il tuo numero di telefono per controllare?"
              - Utente: 206 135 1246
              - Assistente: "Ok, lasciami verificare" // Frase obbligatoria
              - getNextResponseFromSupervisor(relevantContextFromLastUserMessage="Numero di telefono: 206 123 1246")
              - getNextResponseFromSupervisor(): "# Messaggio\nOkay, ho recuperato i dati. L’ultima bolletta è di $xx.xx, principalmente a causa di $y.yy in chiamate internazionali e $z.zz per extra dati. Ha senso?"
              - Assistente: "Ho recuperato i dati. La tua ultima bolletta è di $xx.xx, più alta del solito a causa di $x.xx in chiamate internazionali e $x.xx in costi per extra dati. Ha senso?"
              - Utente: "Sì, grazie."
              - Assistente: "Certamente, fammi sapere se serve altro."
              - Utente: "Vorrei sapere se il mio indirizzo è aggiornato, quale avete in archivio?"
              - Assistente: "1234 Pine St. a Seattle, è l’ultimo?"
              - Utente: "Sì, perfetto, grazie"
              - Assistente: "Ottimo, posso aiutarti con qualcos’altro?"
              - Utente: "No, tutto ok, ciao!"
              - Assistente: "Grazie per aver contattato 'Indigo.ai'!"

              # Ulteriore Esempio (Frase di Riempimento Obbligatoria)
              - Utente: "Puoi dirmi cosa include il mio piano attuale?"
              - Assistente: "Un momento."
              - getNextResponseFromSupervisor(relevantContextFromLastUserMessage="Vuole sapere cosa include il suo piano attuale")
              - getNextResponseFromSupervisor(): "# Messaggio\nIl tuo piano attuale include chiamate e SMS illimitati e 10GB di dati al mese. Vuoi maggiori dettagli o info su un upgrade?"
              - Assistente: "Il tuo piano attuale include chiamate e SMS illimitati e 10GB di dati al mese. Vuoi maggiori dettagli o informazioni su un upgrade?"

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
        "transcript" => user_message
      } ->
        Membrane.Logger.debug("[OpenAi] user message: #{inspect(user_message)}")

        call_api_url(
          %{
            "type" => "save_message",
            "data" => %{
              "role" => "user",
              "content" => user_message
            }
          },
          state
        )

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

        # Task.async(fn ->
          call_get_next_response_from_supervisor(%{
            relevant_context_from_last_user_message: relevant_context_from_last_user_message,
            transcript_logs: state.transcript_logs |> Enum.reverse(),
            call_id: call_id,
            id: id,
            state: state
          })
        # end)

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

        call_api_url(
          %{
            "type" => "save_message",
            "data" => %{
              "role" => "bot",
              "content" => transcript
            }
          },
          state
        )

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
    Membrane.Logger.info(
      "[OpenAi] call_get_next_response_from_supervisor: #{inspect(tool_calling)}"
    )

    request_data = %{
      "target" => "mother_agent",
      "sender" => "tool_call_#{state.sender_id}",
      "data" => %{
        "relevant_context_from_last_user_message" => relevant_context_from_last_user_message,
        "transcript_logs" => Jason.encode!(transcript_logs)
      },
      "last_user_message" => relevant_context_from_last_user_message,
      "should_save_input" => false,
      "should_save_output" => false,
      "force_create_chat" => false
    }

    # Make HTTP POST request to the external service
    tool_base_url = Application.get_env(:membrane_v2v_demo_app, :tool_base_url)
    tool_api_key = Application.get_env(:membrane_v2v_demo_app, :tool_api_key)

    Membrane.Logger.info(
      "[OpenAi] call_get_next_response_from_supervisor request body: #{inspect(request_data)}"
    )

    case Req.post(tool_base_url,
           json: request_data,
           headers: [
             {"Authorization", "Bearer #{tool_api_key}"}
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Membrane.Logger.info("[OpenAi] Supervisor response: #{inspect(body)}")

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

  def call_api_url(data, state) do
    request_data = %{
      "sender" => "#{state.sender_id}",
      "source" => "voice",
      "data" => data
    }

    # Make HTTP POST request to the external service
    api_base_url = Application.get_env(:membrane_v2v_demo_app, :api_base_url)
    tool_api_key = Application.get_env(:membrane_v2v_demo_app, :tool_api_key)

    Membrane.Logger.info("[OpenAi] save_message request body: #{inspect(request_data)}")

    case Req.post(api_base_url,
           json: request_data,
           headers: [
             {"Authorization", "Bearer #{tool_api_key}"}
           ]
         ) do
      {:ok, %Req.Response{status: 200}} ->
        Membrane.Logger.info("[OpenAi] save_message ok")

      {:ok, %Req.Response{status: status_code} = response} ->
        Membrane.Logger.info("[OpenAi] save_message error, #{inspect(response)}")

      {:error, reason} ->
        Membrane.Logger.info("[OpenAi] save_message error reason: #{inspect(reason)}")
    end
  end
end
