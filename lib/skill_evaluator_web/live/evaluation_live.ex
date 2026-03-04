defmodule SkillEvaluatorWeb.EvaluationLive do
  use SkillEvaluatorWeb, :live_view

  @scenarios [
    %{
      id: "python",
      title: "Python Expert",
      description:
        "Test your advanced Python knowledge, including asyncio, metaclasses, and memory management.",
      icon: "hero-code-bracket"
    },
    %{
      id: "javascript",
      title: "JavaScript Engineer",
      description:
        "Evaluate your modern JS skills: closures, event loop, React concepts, and DOM manipulation.",
      icon: "hero-document-text"
    },
    %{
      id: "cybersecurity",
      title: "Cybersecurity Analyst",
      description:
        "Defend against OWASP top 10, explain encryption protocols, and demonstrate threat modeling.",
      icon: "hero-shield-check"
    },
    %{
      id: "ai",
      title: "AI & ML Practitioner",
      description:
        "Discuss transformers, gradient descent, RAG architectures, and fine-tuning strategies.",
      icon: "hero-cpu-chip"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       scenarios: @scenarios,
       active_scenario: nil,
       status: :idle,
       evaluation: nil,
       time_left: 90,
       ai_speaking: false,
       ai_transcript: "",
       eval_task: nil
     )}
  end

  @impl true
  def handle_event("select_scenario", %{"id" => id}, socket) do
    scenario = Enum.find(@scenarios, &(&1.id == id))
    {:noreply, assign(socket, active_scenario: scenario, status: :ready)}
  end

  @impl true
  def handle_event("start_evaluation", _params, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :tick)
    end

    prompt =
      "You are interviewing a candidate for #{socket.assigns.active_scenario.title}. Talk to them in a friendly but evaluating tone. Only respond with audio modalities."

    # Start Gemini Client
    {:ok, gemini_pid} =
      SkillEvaluator.Gemini.LiveClient.start_link(
        parent_pid: self(),
        scenario_prompt: prompt
      )

    {:noreply,
     assign(socket, status: :active, time_left: 90, gemini_pid: gemini_pid, ai_speaking: true)}
  end

  @impl true
  def handle_event("cancel_evaluation", _params, socket) do
    if Map.has_key?(socket.assigns, :gemini_pid) && Process.alive?(socket.assigns.gemini_pid) do
      Process.exit(socket.assigns.gemini_pid, :normal)
    end

    {:noreply,
     assign(socket,
       active_scenario: nil,
       status: :idle,
       evaluation: nil,
       time_left: 90,
       eval_task: nil
     )}
  end

  # Handle audio chunks coming from the JS hook
  @impl true
  def handle_event("audio_chunk", %{"data" => base64_data}, socket) do
    if Map.has_key?(socket.assigns, :gemini_pid) do
      send(socket.assigns.gemini_pid, {:send_audio, base64_data})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("user_silence_timeout", _params, socket) do
    if Map.has_key?(socket.assigns, :gemini_pid) do
      send(socket.assigns.gemini_pid, {:nudge_gemini})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("mic_error", %{"reason" => reason}, socket) do
    if Map.has_key?(socket.assigns, :gemini_pid) && Process.alive?(socket.assigns.gemini_pid) do
      Process.exit(socket.assigns.gemini_pid, :normal)
    end

    socket =
      socket
      |> put_flash(
        :error,
        "Microphone access failed: #{reason}. Please allow microphone permissions and try again."
      )
      |> assign(status: :ready, time_left: 90, evaluation: nil, eval_task: nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    case socket.assigns do
      %{status: :active, time_left: t} when t > 1 ->
        {:noreply, assign(socket, time_left: t - 1)}

      %{status: :active, time_left: 1} ->
        # Timer finished. Stop recording and ask Gemini for the final assessment
        if Map.has_key?(socket.assigns, :gemini_pid) && Process.alive?(socket.assigns.gemini_pid) do
          Process.exit(socket.assigns.gemini_pid, :normal)
        end

        scenario = socket.assigns.active_scenario
        ai_transcript = socket.assigns.ai_transcript

        # Start async evaluation
        task =
          Task.async(fn ->
            SkillEvaluator.Gemini.Assessment.evaluate_skills(
              scenario.title,
              scenario.description,
              ai_transcript
            )
          end)

        socket =
          socket
          |> assign(time_left: 0, status: :completed, eval_task: task)
          |> push_event("stop_recording", %{})

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # Receive audio from Gemini LiveClient
  @impl true
  def handle_info({:gemini_audio, base64_audio}, socket) do
    if socket.assigns.status == :active do
      {:noreply, push_event(socket, "play_audio", %{audio_base64: base64_audio})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:gemini_speech_started}, socket) do
    if socket.assigns.status == :active do
      socket =
        socket
        |> assign(ai_speaking: true)
        |> push_event("disable_mic", %{})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:gemini_turn_complete}, socket) do
    if socket.assigns.status == :active do
      socket =
        socket
        |> assign(ai_speaking: false)
        |> push_event("enable_mic", %{})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:gemini_text, text}, socket) do
    if socket.assigns.status == :active do
      new_transcript = socket.assigns.ai_transcript <> text
      {:noreply, assign(socket, ai_transcript: new_transcript)}
    else
      {:noreply, socket}
    end
  end

  # Handle task completion for evaluation
  @impl true
  def handle_info({ref, result}, %{assigns: %{eval_task: %Task{ref: task_ref}}} = socket)
      when ref == task_ref do
    Process.demonitor(ref, [:flush])
    {:noreply, assign(socket, evaluation: result, eval_task: nil)}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{assigns: %{eval_task: %Task{ref: task_ref}}} = socket
      )
      when ref == task_ref do
    {:noreply, assign(socket, eval_task: nil)}
  end

  # Fallback for irrelevant info messages like old DOWN or old tasks
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-12 px-4 sm:px-6 lg:px-8">
      <div class="text-center mb-12">
        <h1 class="text-4xl font-extrabold text-base-content tracking-tight sm:text-5xl">
          Real-time <span class="text-primary">Skill Evaluator</span>
        </h1>
        <p class="mt-4 text-xl text-base-content/70">
          Have a 90-second conversation with our AI avatar to assess your technical expertise.
        </p>
      </div>

      <%= case @status do %>
        <% :idle -> %>
          <div class="grid grid-cols-1 gap-6 sm:grid-cols-2">
            <%= for scenario <- @scenarios do %>
              <div
                phx-click="select_scenario"
                phx-value-id={scenario.id}
                class="relative rounded-lg border border-base-300 bg-base-100 px-6 py-5 shadow-sm flex items-center space-x-3 hover:border-primary hover:ring-1 hover:ring-primary focus-within:ring-2 focus-within:ring-offset-2 focus-within:ring-primary cursor-pointer transition-all duration-200"
              >
                <div class="flex-shrink-0 text-primary">
                  <.icon name={scenario.icon} class="h-8 w-8" />
                </div>
                <div class="flex-1 min-w-0">
                  <span class="absolute inset-0" aria-hidden="true"></span>
                  <p class="text-lg font-medium text-base-content">{scenario.title}</p>
                  <p class="text-sm text-base-content/70 truncate">{scenario.description}</p>
                </div>
              </div>
            <% end %>
          </div>
        <% :ready -> %>
          <div class="bg-base-100 shadow sm:rounded-lg border border-base-300">
            <div class="px-4 py-5 sm:p-6 text-center">
              <h3 class="text-2xl font-bold leading-6 text-base-content mb-4">
                Ready for {@active_scenario.title}?
              </h3>
              <div class="mt-2 max-w-xl mx-auto text-base-content/70">
                <p>
                  You will have exactly 90 seconds to converse with the evaluator. Try to demonstrate your knowledge clearly. Ensure your microphone is ready.
                </p>
              </div>
              <div class="mt-8 flex justify-center gap-4">
                <button
                  phx-click="cancel_evaluation"
                  class="inline-flex items-center px-4 py-2 border border-base-300 shadow-sm text-base font-medium rounded-md text-base-content bg-base-100 hover:bg-base-200 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-primary"
                >
                  Go Back
                </button>
                <button
                  phx-click="start_evaluation"
                  onclick="if(!window.globalAudioContext) { window.globalAudioContext = new (window.AudioContext || window.webkitAudioContext)({sampleRate: 24000}); window.globalAudioContext.resume(); }"
                  class="inline-flex items-center px-6 py-3 border border-transparent text-base font-medium rounded-md shadow-sm text-primary-content bg-primary hover:brightness-110 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-primary"
                >
                  Start Evaluation
                </button>
              </div>
            </div>
          </div>
        <% :active -> %>
          <div
            id="audio-streamer"
            phx-hook="AudioStreamer"
            class="bg-base-200 shadow sm:rounded-lg border border-primary/50"
            phx-mounted={JS.dispatch("start_recording")}
          >
            <div class="px-4 py-10 sm:p-10 text-center relative overflow-hidden">
              <!-- Pulsing background effect for active recording -->
              <div class="absolute inset-0 flex items-center justify-center opacity-20 pointer-events-none">
                <div class="w-64 h-64 bg-primary rounded-full mix-blend-screen filter blur-3xl animate-pulse">
                </div>
              </div>

              <h3 class="text-2xl font-bold leading-6 text-primary relative z-10">
                Evaluation in Progress
              </h3>

              <div class="mt-2 text-5xl font-mono font-bold text-primary relative z-10 drop-shadow-md">
                00:{@time_left |> Integer.to_string() |> String.pad_leading(2, "0")}
              </div>

              <div class="mt-6 flex justify-center relative z-10">
                <div class="flex items-center gap-2">
                  <span class="flex h-4 w-4 relative">
                    <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-error opacity-75">
                    </span>
                    <span class="relative inline-flex rounded-full h-4 w-4 bg-error"></span>
                  </span>
                  <span class="text-lg font-semibold text-base-content/90">
                    <%= if @ai_speaking do %>
                      AI Interviewer is speaking...
                    <% else %>
                      Listening & Analyzing...
                    <% end %>
                  </span>
                </div>
              </div>
              <div class="mt-6 mx-auto max-w-2xl bg-base-100 p-4 rounded-lg shadow-inner border border-base-300 relative z-10 min-h-[4rem]">
                <p class="text-base-content/90 italic font-medium whitespace-pre-wrap">
                  {@ai_transcript}
                </p>
                <%= if @ai_transcript == "" && @ai_speaking do %>
                  <p class="text-base-content/50 italic animate-pulse">
                    Connecting to audio stream...
                  </p>
                <% end %>
              </div>
              <div class="mt-8 relative z-10">
                <!-- Placeholder for future Audio Visualizer -->
                <div class="h-16 w-full max-w-md mx-auto bg-base-300/50 rounded animate-pulse"></div>
              </div>
            </div>
          </div>
        <% :completed -> %>
          <div class="bg-base-100 shadow sm:rounded-lg border border-base-300">
            <div class="px-4 py-5 sm:p-6">
              <h3 class="text-3xl font-bold leading-6 text-success mb-6 text-center">
                Evaluation Complete
              </h3>
              <div class="max-w-none px-2 sm:px-8 py-4">
                <%= if @evaluation do %>
                  <div class="bg-base-200 p-8 rounded-xl border border-base-300 shadow-lg">
                    <h4 class="text-xl font-bold text-primary border-b border-primary/20 pb-2 mb-3">
                      Summary
                    </h4>
                    <p class="text-base-content/90 leading-relaxed mb-6">{@evaluation.summary}</p>

                    <h4 class="text-xl font-bold text-success border-b border-success/20 pb-2 mb-3">
                      Positives
                    </h4>
                    <p class="text-base-content/90 leading-relaxed mb-6">{@evaluation.positives}</p>

                    <h4 class="text-xl font-bold text-warning border-b border-warning/20 pb-2 mb-3">
                      Areas to Improve
                    </h4>
                    <p class="text-base-content/90 leading-relaxed mb-6">
                      {@evaluation.areas_to_improve}
                    </p>

                    <h4 class="text-xl font-bold text-info border-b border-info/20 pb-2 mb-3">
                      Action Items
                    </h4>
                    <p class="text-base-content/90 leading-relaxed">{@evaluation.action_items}</p>
                  </div>
                <% else %>
                  <div class="text-center py-12">
                    <svg
                      class="animate-spin h-10 w-10 text-primary mx-auto mb-4"
                      xmlns="http://www.w3.org/2000/svg"
                      fill="none"
                      viewBox="0 0 24 24"
                    >
                      <circle
                        class="opacity-25"
                        cx="12"
                        cy="12"
                        r="10"
                        stroke="currentColor"
                        stroke-width="4"
                      >
                      </circle>
                      <path
                        class="opacity-75"
                        fill="currentColor"
                        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                      >
                      </path>
                    </svg>
                    <p class="text-base-content/80 text-lg">
                      Generating your comprehensive feedback...
                    </p>
                  </div>
                <% end %>
              </div>
              <div class="mt-8 flex justify-center">
                <button
                  phx-click="cancel_evaluation"
                  class="inline-flex items-center px-8 py-3 border border-transparent text-lg font-bold rounded-md shadow-lg text-primary-content bg-primary hover:brightness-110 transition-all"
                >
                  Start New Session
                </button>
              </div>
            </div>
          </div>
      <% end %>
    </div>
    """
  end
end
