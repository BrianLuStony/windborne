# app/services/open_meteo_client.rb
require "net/http"
require "json"
require "time"
require "uri"

class OpenMeteoClient
  FORECAST_URL = "https://api.open-meteo.com/v1/forecast".freeze
  ARCHIVE_URL  = "https://archive-api.open-meteo.com/v1/era5".freeze

  # Returns:
  #  - data: { windspeed: Float(km/h), winddirection: Float(deg) } or nil
  #  - dbg:  diagnostics hash (status codes, small body snippets, urls)
  def self.fetch(lat, lon, time_utc, want_debug: false)
    return [nil, dbg_error("invalid_args")] if [lat, lon, time_utc].any?(&:nil?)

    # normalize to hour
    t_utc      = time_utc.utc
    hour_start = Time.at((t_utc.to_i / 3600) * 3600).utc
    day_str    = hour_start.strftime("%Y-%m-%d")

    cache_key = "openmeteo:v3:#{lat.round(3)},#{lon.round(3)}:#{hour_start.to_i}"
    data = Rails.cache.fetch(cache_key, expires_in: 30.minutes) do
      # Try ERA5 archive first (reliable for past hours)
      arch_uri = URI(ARCHIVE_URL)
      arch_uri.query = URI.encode_www_form(
        latitude:        lat.round(4),
        longitude:       lon.round(4),
        start_date:      day_str,
        end_date:        day_str,
        hourly:          "wind_speed_10m,wind_direction_10m",
        windspeed_unit:  "kmh",
        timezone:        "UTC",
        timeformat:      "unixtime"
      )
      arch_res = http_get_follow(arch_uri)
      if arch_res[:ok]
        parsed = parse_unixtime_hour(arch_res[:body], hour_start.to_i)
        return parsed if parsed
      end

      # Fallback: forecast API with past_days (covers last ~48h in many regions)
      fc_uri = URI(FORECAST_URL)
      fc_uri.query = URI.encode_www_form(
        latitude:        lat.round(4),
        longitude:       lon.round(4),
        hourly:          "wind_speed_10m,wind_direction_10m",
        past_days:       2,
        windspeed_unit:  "kmh",
        timezone:        "UTC",
        timeformat:      "unixtime"
      )
      fc_res = http_get_follow(fc_uri)
      if fc_res[:ok]
        parsed = parse_unixtime_hour(fc_res[:body], hour_start.to_i)
        return parsed if parsed
      end

      nil
    end

    return [data, nil] unless want_debug

    # Build diagnostics (non-cached)
    dbg = {}
    begin
      arch_uri_dbg = URI(ARCHIVE_URL)
      arch_uri_dbg.query = URI.encode_www_form(
        latitude: lat.round(4), longitude: lon.round(4),
        start_date: day_str, end_date: day_str,
        hourly: "wind_speed_10m,wind_direction_10m",
        windspeed_unit: "kmh", timezone: "UTC", timeformat: "unixtime"
      )
      arch_res_dbg = http_get_follow(arch_uri_dbg)
      dbg[:archive] = slim_res(arch_uri_dbg, arch_res_dbg)

      fc_uri_dbg = URI(FORECAST_URL)
      fc_uri_dbg.query = URI.encode_www_form(
        latitude: lat.round(4), longitude: lon.round(4),
        hourly: "wind_speed_10m,wind_direction_10m",
        past_days: 2, windspeed_unit: "kmh", timezone: "UTC", timeformat: "unixtime"
      )
      fc_res_dbg = http_get_follow(fc_uri_dbg)
      dbg[:forecast] = slim_res(fc_uri_dbg, fc_res_dbg)
    rescue => ex
      dbg[:exception] = "#{ex.class}: #{ex.message}"
    end

    [data, dbg]
  rescue => ex
    want_debug ? [nil, { exception: "#{ex.class}: #{ex.message}" }] : [nil, nil]
  end

  # Convenience used by controller when not debugging
  def self.at(lat, lon, time) = fetch(lat, lon, time, want_debug: false).first

  # ---- helpers ----

  def self.http_get_follow(uri, limit = 3)
    raise "too many redirects" if limit <= 0
    res = http_get(uri)
    return { ok: false, code: nil, body: nil, error: "nil_response" } unless res
    case res
    when Net::HTTPSuccess
      { ok: true, code: res.code.to_i, body: res.body }
    when Net::HTTPRedirection
      new_uri = URI(res["location"]) rescue nil
      return { ok: false, code: res.code.to_i, body: nil, error: "bad_location" } unless new_uri
      http_get_follow(new_uri, limit - 1)
    else
      { ok: false, code: res.code.to_i, body: res.body }
    end
  rescue => ex
    { ok: false, code: nil, body: nil, error: "#{ex.class}: #{ex.message}" }
  end
  private_class_method :http_get_follow

  def self.http_get(uri)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = "windborne-challenge/1.0"
      http.read_timeout = 6
      http.open_timeout = 4
      http.request(req)
    end
  rescue
    nil
  end
  private_class_method :http_get

  # JSON with {"hourly":{"time":[<unix>...], ...}}
  def self.parse_unixtime_hour(body, target_unix)
    json = JSON.parse(body) rescue nil
    hourly = json && json["hourly"]
    return nil unless hourly

    times = hourly["time"]
    ws    = hourly["wind_speed_10m"]
    wd    = hourly["wind_direction_10m"]
    return nil unless times.is_a?(Array) && ws.is_a?(Array) && wd.is_a?(Array) && !times.empty?

    # find nearest index
    min = Float::INFINITY
    idx = nil
    times.each_with_index do |t, i|
      ti = t.to_i rescue next
      d  = (ti - target_unix).abs
      if d < min
        min = d
        idx = i
      end
    end
    return nil unless idx

    v = ws[idx]; d = wd[idx]
    return nil if v.nil? || d.nil?
    { windspeed: v.to_f, winddirection: d.to_f }
  end
  private_class_method :parse_unixtime_hour

  def self.slim_res(uri, res)
    body = res[:body].to_s
    {
      url: uri.to_s,
      code: res[:code],
      ok: res[:ok],
      error: res[:error],
      body_head: body[0, 180] # small snippet
    }
  end
  private_class_method :slim_res

  def self.dbg_error(msg) = { error: msg }
  private_class_method :dbg_error
end
