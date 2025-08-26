# app/services/windborne_fetcher.rb
require "net/http"
require "uri"
require "json"
require "time"

class WindborneFetcher
  HOURS = (0..23).map { |h| format("%02d", h) }

  def self.call(max_rows_per_hour: nil) = call_with_meta(max_rows_per_hour: max_rows_per_hour).first

  def self.call_with_meta(max_rows_per_hour: nil)
    now_ms  = (Time.now.to_f * 1000).to_i
    horizon = now_ms - 24*3600*1000

    statuses = {}
    points = HOURS.flat_map do |hh|
      arr, stat = fetch_hour(hh, max_rows_per_hour: max_rows_per_hour)
      statuses[hh] = stat
      arr
    end.compact

    filtered = points.select { |p| p[:t] && p[:t] >= horizon && p[:t] <= now_ms }
    meta = {
      attempted_hours: HOURS.size,
      ok_hours: statuses.count { |_h, s| s[:ok] },
      bad_hours: statuses.count { |_h, s| !s[:ok] },
      hour_statuses: statuses,
      raw_points: points.size,
      kept_points: filtered.size
    }
    [filtered, meta]
  end

  def self.fetch_hour(hh, max_rows_per_hour:)
    url = "https://a.windbornesystems.com/treasure/#{hh}.json"
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = "Mozilla/5.0 (Rails Debug)"
    req["Accept"] = "application/json,text/plain;q=0.9,*/*;q=0.8"

    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 8) do |http|
      http.request(req)
    end

    return [[], { ok: false, code: res.code.to_i, hour: hh, rows: 0 }] unless res.is_a?(Net::HTTPSuccess)

    text = res.body.to_s
    arr  = try_json_array(text) || []
    arr  = arr.first(max_rows_per_hour) if max_rows_per_hour

    base_ts = (Time.now.to_f * 1000).to_i - hh.to_i * 3600_000
    pts = arr.filter_map { |raw| coerce_point(raw, base_ts, hh) }
    stat = { ok: true, code: 200, hour: hh, rows: arr.size, bytes: text.bytesize }
    [pts, stat]

  rescue => e
    [[], { ok: false, error: e.class.to_s, message: e.message, hour: hh, rows: 0 }]
  end

  def self.try_json_array(text)
    j = JSON.parse(text) rescue nil
    return j if j.is_a?(Array)
    return j["data"] if j.is_a?(Hash) && j["data"].is_a?(Array)
    return j["points"] if j.is_a?(Hash) && j["points"].is_a?(Array)
    lines = text.split(/\n+/).map(&:strip).reject(&:empty?) rescue []
    arr = lines.filter_map { |ln| JSON.parse(ln) rescue nil }
    arr.empty? ? nil : arr
  end

  def self.coerce_point(raw, base_ts, hh)
    if raw.is_a?(Array)
      lat, lon = raw[0].to_f, raw[1].to_f
      return nil unless lat.between?(-90,90) && lon.between?(-180,180)
      third = raw[2]
      ts_ms =
        if third.is_a?(Numeric) && third > 1_000_000_000
          third < 1_000_000_000_000 ? (third * 1000.0).to_i : third.to_i
        else
          base_ts
        end
      alt_km = (third.is_a?(Numeric) && third <= 120 ? third.to_f : nil)
      { id: "", lat: lat, lon: lon, t: ts_ms, alt: alt_km, hh: hh.to_i }
    elsif raw.is_a?(Hash)
      get = ->(keys) { k = raw.keys.find { |kk| keys.include?(kk.to_s.downcase) }; k ? raw[k] : nil }
      lat = get.call(%w[lat latitude y])&.to_f
      lon = get.call(%w[lon lng longitude x])&.to_f
      return nil unless lat && lon && lat.between?(-90,90) && lon.between?(-180,180)
      t   = get.call(%w[t ts time timestamp epoch])
      ts_ms =
        if t.is_a?(String) || t.is_a?(Numeric)
          v = t.is_a?(String) ? Time.parse(t).to_i : t.to_i
          v < 1_000_000_000_000 ? v * 1000 : v
        else
          base_ts
        end
      alt = get.call(%w[alt altitude h z])
      { id: (get.call(%w[id name balloon_id flight guid])&.to_s || ""),
        lat: lat, lon: lon, t: ts_ms, alt: alt&.to_f, hh: hh.to_i }
    end
  end
end
