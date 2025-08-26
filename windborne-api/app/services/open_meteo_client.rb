class OpenMeteoClient
  def self.at(_lat, _lon, _time)
    nil
  end

  # Keep the same shape used by the controller’s debug probes (no-op here)
  def self.fetch(lat, lon, time, want_debug: false)
    [nil, want_debug ? { note: "OpenMeteoClient is stubbed (meteo disabled)" } : nil]
  end
end