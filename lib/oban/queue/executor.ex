defmodule Oban.Queue.Executor do
  @moduledoc false

  alias Oban.{Config, Job, Query}

  @type option :: {:conf, Config.t()}

  @spec child_spec([option]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @spec start_link([option], Job.t()) :: {:ok, pid()}
  def start_link([conf: conf], job) do
    Task.start_link(__MODULE__, :call, [job, conf])
  end

  @spec call(job :: Job.t(), conf :: Config.t()) :: :ok
  def call(%Job{} = job, %Config{repo: repo}) do
    {timing, return} = :timer.tc(__MODULE__, :safe_call, [job])

    case return do
      {:success, ^job} ->
        Query.complete_job(repo, job)

        report(timing, job, %{event: :success})

      {:failure, ^job, kind, error, stack} ->
        Query.retry_job(repo, job, Exception.format(kind, error, stack))

        report(timing, job, %{event: :failure, kind: kind, error: error, stack: stack})
    end

    :ok
  end

  @doc false
  def safe_call(%Job{args: args, worker: worker} = job) do
    worker
    |> to_module()
    |> apply(:perform, [args])

    {:success, job}
  rescue
    exception ->
      {:failure, job, :error, exception, __STACKTRACE__}
  catch
    kind, value ->
      {:failure, job, kind, value, __STACKTRACE__}
  end

  # Helpers

  defp to_module(worker) when is_binary(worker) do
    worker
    |> String.split(".")
    |> Module.safe_concat()
  end

  defp to_module(worker) when is_atom(worker), do: worker

  defp report(timing, job, meta) do
    meta =
      job
      |> Map.take([:id, :args, :queue, :worker])
      |> Map.merge(meta)

    :telemetry.execute([:oban, :job, :executed], timing, meta)
  end
end
