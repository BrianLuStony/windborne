# app/controllers/api/constellation_controller.rb
class Api::ConstellationController < ActionController::API
  def index
    bool = ActiveModel::Type::Boolean.new

    # Toggle: if ?no_meteo is not provided, default from ENV ENABLE_METEO (false by default).
    param_no_meteo = params.key?(:no_meteo) ? bool.cast(params[:no_meteo]) : nil
    env_enable     = bool.cast(ENV.fetch("ENABLE_METEO", "false"))
    no_meteo       = param_no_meteo.nil? ? !env_enable : param_no_meteo

    debug     = bool.cast(params[:debug])
    meteo_cap = (params[:meteo_cap].presence || 40).to_i
    meteo_cap = 0 if meteo_cap.negative?
    max_rows  = params[:max_rows_per_hour].presence&.to_i
    max_rows  = nil if max_rows && max_rows <= 0

    cache_key = [
      "constellation:v9",
      "no_meteo=#{no_meteo}",
      "meteo_cap=#{meteo_cap}",
      "max_rows=#{max_rows || 'nil'}"
    ].join(":")

    if debug
      payload = build_payload(no_meteo: no_meteo, meteo_cap: meteo_cap, max_rows: max_rows, debug: true)
      response.set_header "Cache-Control", "no-store"
      render json: payload and return
    end

    # Safe cache (if Solid Cache isn't installed, we still serve)
    payload =
      begin
        Rails.cache.fetch(cache_key, expires_in: 90.seconds) do
          build_payload(no_meteo: no_meteo, meteo_cap: meteo_cap, max_rows: max_rows, debug: false)
        end
      rescue => e
        Rails.logger.warn("cache_fetch_failed: #{e.class}: #{e.message}") rescue nil
        build_payload(no_meteo: no_meteo, meteo_cap: meteo_cap, max_rows: max_rows, debug: false)
      end

    response.set_header "Cache-Control", "public, max-age=60"
    render json: payload
  end

  private

  def build_payload(no_meteo:, meteo_cap:, max_rows:, debug:)
    t0 = mono
    points, fetch_meta = WindborneFetcher.call_with_meta(max_rows_per_hour: max_rows)
    t1 = mono

    tracks = FastTrackBuilder.call(points) # [{ id:, points:[{lat,lon,t}, ...] }, ...]
    t2 = mono

    base = tracks.map do |tr|
      pts = tr[:points] || []
      next if pts.empty?
      last  = pts.last
      drift = VectorMath.drift(tr) # {speedKmh:, headingDeg:}
      {
        id:    tr[:id],
        last:  last,
        drift: drift,
        meteo: nil,
        comp:  nil,
        trail: pts.map { |p| { lat: p[:lat], lon: p[:lon], t: p[:t] } }
      }
    end.compact

    # Meteo enrichment is OPTIONAL (off when no_meteo = true). With this file, it’s off by default.
    enriched_map   = {}
    subset         = []
    meteo_attempts = 0
    meteo_success  = 0
    meteo_errors   = []
    meteo_probes   = []

    unless no_meteo || meteo_cap <= 0 || base.empty?
      sorted = base.sort_by { |e| -(e.dig(:drift, :speedKmh) || 0.0) } # fastest first
      subset = sorted.first(meteo_cap)

      subset.each_with_index do |e, i|
        meteo_attempts += 1
        last  = e[:last]
        drift = e[:drift]
        begin
          # Using the stub client below, this will always be nil unless you later enable a real client.
          m = OpenMeteoClient.at(last[:lat], last[:lon], Time.at(last[:t] / 1000))
          if m
            c = VectorMath.components(drift[:headingDeg], m[:winddirection], m[:windspeed])
            enriched_map[e[:id]] = { meteo: m, comp: c }
            meteo_success += 1
          else
            meteo_errors << "nil meteo at #{last[:lat]},#{last[:lon]}"
          end
        rescue => ex
          meteo_errors << "#{ex.class}: #{ex.message}"
        end
      end

      meteo_errors.uniq!
      meteo_errors = meteo_errors.first(5)
    end

    balloons = base.map { |e| (extra = enriched_map[e[:id]]) ? e.merge(extra) : e }
    t3 = mono

    fastest   = balloons.sort_by { |e| -(e.dig(:drift, :speedKmh) || 0.0) }.first(5) || []
    best_tail = balloons.select { |e| e[:comp].is_a?(Hash) }
                        .sort_by { |e| -(e.dig(:comp, :tailwind) || 0.0) }
                        .first(5) || []

    payload = {
      updatedAt: Time.now.utc.iso8601,
      count: balloons.size,
      balloons: balloons,
      insights: {
        fastest:  fastest,
        bestTail: best_tail # will be [] when meteo is off
      },
      info: {
        meteo_enabled: !no_meteo
      }
    }

    if debug
      payload[:debug] = (fetch_meta || {}).merge(
        {
          tracks_total: tracks.size,
          subset_size: subset.size,
          enriched_count: enriched_map.size,
          meteo: {
            attempts: meteo_attempts,
            success:  meteo_success,
            errors_sample: meteo_errors,
            probes: meteo_probes
          },
          timings_ms: {
            fetch:  ((t1 - t0) * 1000).to_i,
            tracks: ((t2 - t1) * 1000).to_i,
            enrich: ((t3 - t2) * 1000).to_i
          },
          params: {
            no_meteo: no_meteo, meteo_cap: meteo_cap, max_rows_per_hour: max_rows
          },
          insights_counts: {
            fastest: fastest.length, bestTail: best_tail.length
          }
        }
      )
    end

    payload
  end

  def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
