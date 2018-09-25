defmodule NervesHub.FirmwareChannel do
  use PhoenixChannelClient
  require Logger

  alias NervesHub.{HTTPClient, UpdateHandler, DefaultUpdateHandler}
  @update_handler Application.get_env(:nerves_hub, :update_handler, DefaultUpdateHandler)

  def topic do
    "firmware:" <> Nerves.Runtime.KV.get_active("nerves_fw_uuid")
  end

  def handle_in("update", params, state) do
    {:noreply, maybe_update_firmware(params, state)}
  end

  def handle_in(_event, _payload, state) do
    {:noreply, state}
  end

  def handle_reply(
        {:ok, :join, %{"response" => response, "status" => "ok"}, _},
        state
      ) do
    {:noreply, maybe_update_firmware(response, state)}
  end

  def handle_reply(
        {:error, :join, %{"response" => %{"reason" => reason}, "status" => "error"}},
        state
      ) do
    {:stop, reason, state}
  end

  def handle_reply(_payload, state) do
    {:noreply, state}
  end

  def handle_close(_payload, state) do
    Process.send_after(self(), :rejoin, 5_000)
    {:noreply, state}
  end

  def handle_info({:fwup, :done}, state) do
    Logger.info("[NervesHub] FWUP Finished")
    {:noreply, maybe_reboot(state)}
  end

  def handle_info({:update_reschedule, response}, state) do
    {:noreply, maybe_update_firmware(response, state)}
  end

  def handle_info(:reboot_reschedule, state) do
    {:noreply, maybe_reboot(state)}
  end

  defp maybe_update_firmware(%{"firmware_url" => url} = data, state) do
    # Cancel an existing timer if it exists.
    # This prevents rescheduled uodates
    # from compounding.
    state = maybe_cancel_reschedule_timer(state)

    # possibly offload update decision to an external module.
    # This will allow application developers
    # to control exactly when an update is applied.
    if UpdateHandler.should_update?(@update_handler, data) do
      {:ok, http} = HTTPClient.start_link(self())
      HTTPClient.get(http, url)
      Logger.info("[NervesHub] Downloading firmware: #{url}")
      state
    else
      ms = UpdateHandler.update_frequency(@update_handler)

      if ms do
        timer = Process.send_after(self(), {:update_reschedule, data}, ms)
        Logger.info("[NervesHub] rescheduling firmware update in #{ms} milliseconds")
        Map.put(state, :update_reschedule_timer, timer)
      else
        state
      end
    end
  end

  defp maybe_update_firmware(_, state), do: state

  defp maybe_reboot(state) do
    if UpdateHandler.should_reboot?(@update_handler) do
      Nerves.Runtime.reboot()
      state
    else
      ms = UpdateHandler.reboot_frequency(@update_handler)

      if ms do
        timer = Process.send_after(self(), :reboot_reschedule, ms)
        Logger.info("[NervesHub] rescheduling firmware update in #{ms} milliseconds")
        Map.put(state, :reboot_reschedule_timer, timer)
      else
        state
      end
    end
  end

  defp maybe_cancel_reschedule_timer(state) do
    timer = Map.get(state, :reschedule_timer)

    if timer && Process.read_timer(timer) do
      Process.cancel_timer(timer)
    end

    Map.delete(state, :reschedule_timer)
  end
end
