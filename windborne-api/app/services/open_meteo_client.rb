# app/services/open_meteo_client.rb
require "net/http"
require "json"
require "time"

class OpenMeteoClient
  FORECAST_HOST = "https://api.open-meteo.com/v1/forecast".freeze
  ARCHIVE_HOST  = "https://archive-api.open-meteo.com/v1/era5".freeze

  # Returns { windspeed: Float(km/h), winddirection: Float(deg) } or nil.
  # Picks the hourly value nearest to +time+ (UTC).
  def self.at(lat, lon, time)
    return nil if lat.nil? || lon.nil? || time.nil?

    t_utc      = time.utc
    hour_start = Time.at((t_utc.to_i / 3600) * 3600).utc
    date_str   = hour_start.strftime("%Y-%m-%d")

    # Cache by rounded coords + hour
    cache_key = "openmeteo:v2:#{lat.round(3)},#{lon.round(3)}:#{hour_start.to_i}"
    Rails.cache.fetch(cache_key, expires_in: 30.minutes) do
      # 1) Try ERA5 archive (best for past hours, globally available)
      arch_uri = URI(ARCHIVE_HOST)
      arch_uri.query = URI.encode_www_form(
        latitude:        lat.round(4),
        longitude:       lon.round(4),
        start_date:      date_str,
        end_date:        date_str,
        hourly:          "wind_speed_10m,wind_direction_10m",
        windspeed_unit:  "kmh",
        timezone:        "UTC",
        timeformat:      "unixtime"
      )
      res = http_get(arch_uri)
      if res&.is_a?(Net::HTTPSuccess)
        val = parse_unixtime_hour(res.body, hour_start.to_i)
        return val if val
      end

      # 2) Fallback: forecast API with past_days=2
      fc_uri = URI(FORECAST_HOST)
      fc_uri.query = URI.encode_www_form(
        latitude:        lat.round(4),
        longitude:       lon.round(4),
        hourly:          "wind_speed_10m,wind_direction_10m",
        past_days:       2,
        windspeed_unit:  "kmh",
        timezone:        "UTC"
      )
      res2 = http_get(fc_uri)
      if res2&.is_a?(Net::HTTPSuccess)
        val = parse_isotime_hour(res2.body, hour_start)
        return val if val
      end

      nil
    end
  rescue StandardError
    nil
  end

  # ---- helpers ----

  # JSON with {"hourly":{"time":[<unix>...], "wind_speed_10m":[...], "wind_direction_10m":[...]}}
  def self.parse_unixtime_hour(body, target_unix)
    json = JSON.parse(body) rescue nil
    hourly = json && json["hourly"]
    return nil unless hourly

    times = hourly["time"]
    ws    = hourly["wind_speed_10m"]
    wd    = hourly["wind_direction_10m"]
    return nil unless times && ws && wd && times.is_a?(Array)

    idx = nearest_index_unix(times, target_unix)
    return nil unless idx

    v = ws[idx]; d = wd[idx]
    return nil if v.nil? || d.nil?
    { windspeed: v.to_f, winddirection: d.to_f }
  end
  private_class_method :parse_unixtime_hour

  # JSON with {"hourly":{"time":["YYYY-MM-DDTHH:00"...], ...}}
  def self.parse_isotime_hour(body, target_time_utc)
    json = JSON.parse(body) rescue nil
    hourly = json && json["hourly"]
    return nil unless hourly

    times = hourly["time"]
    ws    = hourly["wind_speed_10m"]
    wd    = hourly["wind_direction_10m"]
    return nil unless times && ws && wd && times.is_a?(Array)

    # Exact hour match first; fallback to nearest
    target_iso = target_time_utc.strftime("%Y-%m-%dT%H:00")
    idx = times.index(target_iso) || nearest_index_iso(times, target_time_utc)
    return nil unless idx

    v = ws[idx]; d = wd[idx]
    return nil if v.nil? || d.nil?
    { windspeed: v.to_f, winddirection: d.to_f }
  end
  private_class_method :parse_isotime_hour

  def self.nearest_index_unix(unix_times, target_unix)
    min = Float::INFINITY
    mini = nil
    unix_times.each_with_index do |t, i|
      ti = t.to_i rescue next
      d  = (ti - target_unix).abs
      if d < min
        min  = d
        mini = i
      end
    end
    mini
  end
  private_class_method :nearest_index_unix

  def self.nearest_index_iso(times_iso, target_time_utc)
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
  private_class_method :nearest_index_iso

  def self.http_get(uri)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = "windborne-challenge/1.0"
      http.read_timeout = 5
      http.open_timeout = 3
      http.request(req)
    end
  rescue StandardError
    nil
  end
  private_class_method :http_get
end
