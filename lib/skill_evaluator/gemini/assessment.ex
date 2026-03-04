defmodule SkillEvaluator.Gemini.Assessment do
  @moduledoc """
  Handles the final structural text assessment by summarizing the interaction
  and scoring the candidate using the standard Gemini REST API.
  """
  require Logger

  @gemini_url "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-pro-preview:generateContent"

  def evaluate_skills(scenario_title, scenario_description, transcript) do
    api_key = Application.get_env(:skill_evaluator, :api_keys)[:gemini]
    url = "#{@gemini_url}?key=#{api_key}"

    # We ask Gemini to generate structured JSON according to our schema
    prompt = """
    You are an expert technical interviewer evaluating a candidate for the following role:
    Title: #{scenario_title}
    Description: #{scenario_description}

    You just finished a 90-second rapid-fire real-time interview with the candidate.
    Below is the verbatim transcript of what YOU (the AI interviewer) said during the interview.
    You must intelligently infer what the candidate said and how well they performed based entirely on your own responses to them!

    INTERVIEWER TRANSCRIPT:
    #{transcript}

    Based on this context, generate a final assessment scorecard in JSON format.

    Your JSON must have the following exact schema:
    {
      "summary": "overall summary...",
      "positives": "what they did well...",
      "areas_to_improve": "what they failed at...",
      "action_items": "bulleted list of next steps..."
    }

    Do not wrap with markdown code blocks. Return ONLY raw JSON.
    """

    body = %{
      "contents" => [
        %{
          "parts" => [%{"text" => prompt}]
        }
      ],
      "generationConfig" => %{
        "responseMimeType" => "application/json"
      }
    }

    case Req.post(url, json: body) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        try do
          text =
            get_in(resp_body, [
              "candidates",
              Access.at(0),
              "content",
              "parts",
              Access.at(0),
              "text"
            ])

          Jason.decode!(text) |> atomic_keys()
        rescue
          e ->
            Logger.error("Failed to parse Gemini Assessment JSON: #{inspect(e)}")
            fallback_evaluation()
        end

      {:ok, response} ->
        Logger.error("Gemini API error: #{inspect(response)}")
        fallback_evaluation()

      {:error, reason} ->
        Logger.error("Request failed: #{inspect(reason)}")
        fallback_evaluation()
    end
  end

  defp atomic_keys(map) do
    for {k, v} <- map, into: %{}, do: {String.to_atom(k), v}
  end

  defp fallback_evaluation() do
    %{
      summary: "We couldn't reach the evaluation server. You still did great!",
      positives: "Took initiative to try the system.",
      areas_to_improve: "System resilience needs work.",
      action_items: "Check terminal logs for errors."
    }
  end
end
