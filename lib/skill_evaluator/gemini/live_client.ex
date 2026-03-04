defmodule SkillEvaluator.Gemini.LiveClient do
  @moduledoc """
  Connects to the Gemini Multimodal Live API using WebSockets.
  """
  use WebSockex
  require Logger

  @gemini_url "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent"

  def start_link(opts) do
    parent_pid = Keyword.fetch!(opts, :parent_pid)
    scenario_prompt = Keyword.fetch!(opts, :scenario_prompt)
    api_key = Application.get_env(:skill_evaluator, :api_keys)[:gemini]

    url = "#{@gemini_url}?key=#{api_key}"

    state = %{
      parent_pid: parent_pid,
      scenario_prompt: scenario_prompt,
      connected: false,
      collecting_evaluation: false,
      evaluation_buffer: ""
    }

    WebSockex.start_link(url, __MODULE__, state)
  end

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("Connected to Gemini Live API")

    # Send the initial setup message
    setup_msg = %{
      "setup" => %{
        "model" => "models/gemini-2.5-flash-native-audio-preview-12-2025",
        "systemInstruction" => %{
          "parts" => [%{"text" => state.scenario_prompt}]
        },
        "generationConfig" => %{
          "responseModalities" => ["AUDIO"]
        }
      }
    }

    send(self(), {:send_json, setup_msg})

    # Prompt Gemini to introduce itself and start the interview
    init_msg = %{
      "clientContent" => %{
        "turns" => [
          %{
            "role" => "user",
            "parts" => [
              %{
                "text" =>
                  "Hello, I am ready for the interview! Please introduce yourself and ask me the first question."
              }
            ]
          }
        ],
        "turnComplete" => true
      }
    }

    # Delay slightly to ensure setup is processed first
    Process.send_after(self(), {:send_json, init_msg}, 500)

    {:ok, %{state | connected: true}}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    process_frame(msg, state)
  end

  @impl true
  def handle_frame({:binary, msg}, state) do
    process_frame(msg, state)
  end

  defp process_frame(msg, state) do
    try do
      decoded = Jason.decode!(msg)

      if server_content = decoded["serverContent"] do
        state =
          if model_turn = server_content["modelTurn"] do
            if not state.collecting_evaluation do
              send(state.parent_pid, {:gemini_speech_started})
            end

            texts =
              if parts = model_turn["parts"] do
                Enum.map(parts, fn part ->
                  if inline_data = part["inlineData"] do
                    if String.starts_with?(inline_data["mimeType"] || "", "audio/") do
                      base64_audio = inline_data["data"]

                      # Only output audio if not collecting assessment so it doesn't speak the JSON
                      if not state.collecting_evaluation do
                        send(state.parent_pid, {:gemini_audio, base64_audio})
                      end
                    end
                  end

                  part["text"]
                end)
                |> Enum.reject(&is_nil/1)
              else
                []
              end

            if state.collecting_evaluation do
              %{state | evaluation_buffer: state.evaluation_buffer <> Enum.join(texts)}
            else
              Enum.each(texts, fn t -> send(state.parent_pid, {:gemini_text, t}) end)
              state
            end
          else
            state
          end

        if server_content["turnComplete"] do
          Logger.info("Gemini finished reciting turn.")

          if state.collecting_evaluation do
            parsed = parse_evaluation(state.evaluation_buffer)
            send(state.parent_pid, {:evaluation_ready, parsed})
            send(self(), :close_connection)
          else
            send(state.parent_pid, {:gemini_turn_complete})
          end
        end

        {:ok, state}
      else
        {:ok, state}
      end
    rescue
      e ->
        Logger.warning("Failed to parse Gemini frame: #{inspect(e)}")
        {:ok, state}
    end
  end

  defp parse_evaluation(raw_text) do
    clean_text = raw_text |> String.replace(~r/```json|```/, "") |> String.trim()

    try do
      Jason.decode!(clean_text) |> atomic_keys()
    rescue
      _e ->
        %{
          summary: "Failed to parse final evaluation. Raw text: #{clean_text}",
          positives: "N/A",
          areas_to_improve: "N/A",
          action_items: "N/A"
        }
    end
  end

  defp atomic_keys(map) do
    for {k, v} <- map, into: %{}, do: {String.to_atom(k), v}
  end

  @impl true
  def handle_info({:send_json, map}, state) do
    json = Jason.encode!(map)
    {:reply, {:text, json}, state}
  end

  @impl true
  def handle_info(:close_connection, state) do
    {:close, state}
  end

  @impl true
  def handle_info({:generate_assessment}, state) do
    Logger.info("Requesting final structured assessment from Gemini Live...")

    prompt = %{
      "clientContent" => %{
        "turns" => [
          %{
            "role" => "user",
            "parts" => [
              %{
                "text" =>
                  "The 90-second interview is now complete. Please stop speaking audio entirely. Evaluate my performance during this exact interview based firmly on what I just said. Return ONLY a valid JSON scorecard with exactly the following keys: {\"summary\": \"...\", \"positives\": \"...\", \"areas_to_improve\": \"...\", \"action_items\": \"...\"}. Do not use markdown syntax, wrap in ```json, or output anything else."
              }
            ]
          }
        ],
        "turnComplete" => true
      }
    }

    send(self(), {:send_json, prompt})
    {:noreply, %{state | collecting_evaluation: true}}
  end

  @impl true
  def handle_info({:send_audio, base64_pcm}, state) do
    # Gemini Live expects base64 audio string packaged in RealtimeInput
    msg = %{
      "realtimeInput" => %{
        "mediaChunks" => [
          %{
            "mimeType" => "audio/pcm;rate=16000",
            "data" => base64_pcm
          }
        ]
      }
    }

    send(self(), {:send_json, msg})
    {:ok, state}
  end

  @impl true
  def handle_info({:nudge_gemini}, state) do
    nudge_msg = %{
      "clientContent" => %{
        "turns" => [
          %{
            "role" => "user",
            "parts" => [
              %{
                "text" =>
                  "I am done answering. Please evaluate my response or ask the next question."
              }
            ]
          }
        ],
        "turnComplete" => true
      }
    }

    send(self(), {:send_json, nudge_msg})
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.info("Disconnected from Gemini: #{inspect(reason)}")
    {:ok, %{state | connected: false}}
  end
end
