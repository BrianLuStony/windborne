# app/controllers/api/constellation_controller.rb
class Api::ConstellationController < ActionController::API
  def index
    # ---------- params ----------
    debug     = ActiveModel::Type::Boolean.new.cast(params[:debug])
    no_meteo  = ActiveModel::Type::Boolean.new.cast(params[:no_meteo])
    meteo_cap = (params[:meteo_cap].presence || 40).to_i
    meteo_cap = 0 if meteo_cap.negative?
    max_rows  = params[:max_rows_per_hour].presence&.to_i
    max_rows  = nil if max_rows && max_rows <= 0

    # ---------- cache ----------
    # Include all behavior-affecting params in the cache key.
    # Bypass cache when debug is on so you always see live debug fields.
    cache_key = [
      "constellation:v6",
      "no_meteo=#{no_meteo}",
      "meteo_cap=#{meteo_cap}",
      "max_rows=#{max_rows || 'nil'}"
    ].join(":")

    if debug
      payload = build_payload(no_meteo: no_meteo, meteo_cap: meteo_cap, max_rows: max_rows, debug: true)
      response.set_header "Cache-Control", "no-store"
      render json: payload and return
    end

    payload = Rails.cache.fetch(cache_key, expires_in: 90.seconds) do
      build_payload(no_meteo: no_meteo, meteo_cap: meteo_cap, max_rows: max_rows, debug: false)
    end

    # public cache for browsers
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

    # Base list for ALL tracks
    base = tracks.map do |tr|
      last  = tr[:points].last
      drift = VectorMath.drift(tr) # {speedKmh:, headingDeg:}
      {
        id:    tr[:id],
        last:  last,
        drift: drift,
        meteo: nil,
        comp:  nil,
        trail: tr[:points].map { |p| { lat: p[:lat], lon: p[:lon], t: p[:t] } }
      }
    end

    # ---- Enrichment (subset) ----
    enriched_map = {}
    subset = []
    meteo_attempts = 0
    meteo_success  = 0
    meteo_errors   = []

    unless no_meteo || meteo_cap <= 0 || base.empty?
      # enrich the most "interesting" first: fastest drift
      sorted = base.sort_by { |e| -(e.dig(:drift, :speedKmh) || 0.0) }
      subset = sorted.first(meteo_cap)

      subset.each do |e|
        meteo_attempts += 1
        begin
          last  = e[:last]
          drift = e[:drift]
          # NOTE: OpenMeteoClient.at should return {windspeed:, winddirection:} or nil
          meteo = OpenMeteoClient.at(last[:lat], last[:lon], Time.at(last[:t] / 1000))
          if meteo
            comp  = VectorMath.components(drift[:headingDeg], meteo[:winddirection], meteo[:windspeed])
            enriched_map[e[:id]] = { meteo: meteo, comp: comp }
            meteo_success += 1
          else
            meteo_errors << "nil response at #{last[:lat]},#{last[:lon]}"
          end
        rescue => ex
          meteo_errors << "#{ex.class}: #{ex.message}"
          meteo_errors.uniq!
          meteo_errors = meteo_errors.first(5) # cap noise
        end
      end
    end

    # Merge enrichment back into ALL base entries
    balloons = base.map { |e| (extra = enriched_map[e[:id]]) ? e.merge(extra) : e }
    t3 = mono

    # Insights
    fastest  = balloons.sort_by { |e| -(e.dig(:drift, :speedKmh) || 0.0) }.first(5)
    best_tail_candidates = balloons.select { |e| e[:comp].is_a?(Hash) }
    best_tail = best_tail_candidates
                  .sort_by { |e| -(e.dig(:comp, :tailwind) || 0.0) }
                  .first(5) || []

    payload = {
      updatedAt: Time.now.utc.iso8601,
      count: balloons.size,
      balloons: balloons,
      insights: {
        fastest: fastest || [],
        bestTail: best_tail || []
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
            errors_sample: meteo_errors
          },
          timings_ms: {
            fetch:  ((t1 - t0) * 1000).to_i,
            tracks: ((t2 - t1) * 1000).to_i,
            enrich: ((t3 - t2) * 1000).to_i
          },
          params: {
            no_meteo: no_meteo,
            meteo_cap: meteo_cap,
            max_rows_per_hour: max_rows
          },
          insights_counts: {
            fastest: fastest.length,
            bestTail: best_tail.length
          }
        }
      )
    end

    payload
  end

  def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
