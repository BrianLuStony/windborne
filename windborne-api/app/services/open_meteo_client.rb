# app/services/open_meteo_client.rb
require "net/http"
require "json"
require "time"

class OpenMeteoClient
  HOST = "https://api.open-meteo.com"

  # Returns { windspeed: Float(km/h), winddirection: Float(deg) } or nil on failure.
  # Picks the hourly value nearest to +time+ within the last 48 hours (UTC).
  def self.at(lat, lon, time)
    return nil if lat.nil? || lon.nil? || time.nil?

    # Normalize to the start of the hour for a stable cache key
    t_utc      = time.utc
    hour_start = Time.at((t_utc.to_i / 3600) * 3600).utc

    cache_key = "openmeteo:v1:#{lat.round(3)},#{lon.round(3)}:#{hour_start.to_i}"
    Rails.cache.fetch(cache_key, expires_in: 30.minutes) do
      uri = URI("#{HOST}/v1/forecast")
      params = {
        latitude:         lat.round(4),
        longitude:        lon.round(4),
        hourly:           "wind_speed_10m,wind_direction_10m",
        past_hours:       48,       # last 48h only; no future hours
        forecast_hours:   0,
        timezone:         "UTC",
        windspeed_unit:   "kmh"     # ensure km/h for your components math
      }
      uri.query = URI.encode_www_form(params)

      res = http_get(uri)
      return nil unless res.is_a?(Net::HTTPSuccess)

      json = JSON.parse(res.body) rescue nil
      return nil unless json

      hourly      = json["hourly"] || {}
      times_iso   = hourly["time"]
      speeds_kmh  = hourly["wind_speed_10m"]
      dirs_deg    = hourly["wind_direction_10m"]
      return nil unless times_iso && speeds_kmh && dirs_deg

      # Open-Meteo returns ISO like "2025-08-26T14:00"
      target_iso = hour_start.strftime("%Y-%m-%dT%H:00")
      idx = times_iso.index(target_iso) || nearest_index(times_iso, hour_start)
      return nil unless idx

      ws = speeds_kmh[idx]
      wd = dirs_deg[idx]
      return nil if ws.nil? || wd.nil?

      { windspeed: ws.to_f, winddirection: wd.to_f }
    end
  rescue StandardError
    nil
  end

  def self.http_get(uri)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = "windborne-challenge/1.0 (+https://example.com)"
      http.read_timeout = 5
      http.open_timeout = 3
      http.request(req)
    end
  end
  private_class_method :http_get

  def self.nearest_index(times_iso, target_time_utc)
    target_i = target_time_utc.to_i
    min = Float::INFINITY
    mini = nil
    times_iso.each_with_index do |iso, i|
      ti = Time.parse(iso + "Z").to_i rescue next
      d  = (ti - target_i).abs
      if d < min
        min  = d
        mini = i
      end
    end
    mini
  end
  private_class_method :nearest_index
end
