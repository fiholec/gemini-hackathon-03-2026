defmodule SkillEvaluator.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SkillEvaluatorWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:skill_evaluator, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SkillEvaluator.PubSub},
      # Start a worker by calling: SkillEvaluator.Worker.start_link(arg)
      # {SkillEvaluator.Worker, arg},
      # Start to serve requests, typically the last entry
      SkillEvaluatorWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SkillEvaluator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SkillEvaluatorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
