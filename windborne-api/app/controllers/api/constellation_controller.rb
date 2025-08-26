# app/controllers/api/constellation_controller.rb
class Api::ConstellationController < ActionController::API
  def index
    # -------- params --------
    debug      = ActiveModel::Type::Boolean.new.cast(params[:debug])
    no_meteo   = ActiveModel::Type::Boolean.new.cast(params[:no_meteo])
    meteo_cap  = (params[:meteo_cap].presence || 40).to_i
    meteo_cap  = 0 if meteo_cap.negative?
    max_rows   = (params[:max_rows_per_hour].presence || (debug ? 200 : nil)).to_i
    max_rows   = nil if max_rows && max_rows <= 0

    # -------- caching (optional but helpful) --------
    cache_key = [
      "constellation:v5",
      "no_meteo=#{no_meteo}",
      "meteo_cap=#{meteo_cap}",
      "max_rows=#{max_rows || 'nil'}"
    ].join(":")

    payload = Rails.cache.fetch(cache_key, expires_in: 90.seconds) do
      build_payload(no_meteo: no_meteo, meteo_cap: meteo_cap, max_rows: max_rows, debug: debug)
    end

    # add timing/debug after cache fetch (only when debug=1)
    if debug
      payload[:debug] ||= {}
      payload[:debug][:cache] = { hit: false } # we can't know here if it was a hit vs miss; comment out if you prefer
    end

    # public caching header to let browsers share for a minute
    response.set_header "Cache-Control", "public, max-age=60"
    render json: payload
  end

  private

  # Build the full JSON payload once; memoized by Rails.cache in #index
  def build_payload(no_meteo:, meteo_cap:, max_rows:, debug:)
    t0 = now
    points, fetch_meta = WindborneFetcher.call_with_meta(max_rows_per_hour: max_rows)
    t1 = now

    tracks = FastTrackBuilder.call(points) # [{ id:, points:[{lat,lon,t}, ...] }, ...]
    t2 = now

    # Base entries for EVERY track (map renders everything)
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

    # Choose a subset to enrich with wind so Best Tailwind is meaningful
    enriched_map = {}
    subset = []

    unless no_meteo || meteo_cap <= 0 || base.empty?
      # sort by drift speed (fastest first) to enrich the most interesting tracks
      sorted = base.sort_by { |e| -(e.dig(:drift, :speedKmh) || 0.0) }
      subset = sorted.first(meteo_cap)

      subset.each do |e|
        begin
          m = OpenMeteoClient.at(e[:last][:lat], e[:last][:lon], Time.at(e[:last][:t] / 1000))
          if m
            c = VectorMath.components(e[:drift][:headingDeg], m[:winddirection], m[:windspeed])
            enriched_map[e[:id]] = { meteo: m, comp: c }
          end
        rescue StandardError
          # swallow per-track meteo failures; the rest still render
        end
      end
    end

    # Merge enrichment back into ALL base entries
    balloons = base.map { |e| (extra = enriched_map[e[:id]]) ? e.merge(extra) : e }
    t3 = now

    # Insights
    fastest  = balloons.sort_by { |e| -(e.dig(:drift, :speedKmh) || 0.0) }.first(5)
    bestTail = balloons.select { |e| e[:comp].is_a?(Hash) }
                       .sort_by { |e| -(e.dig(:comp, :tailwind) || 0.0) }
                       .first(5)

    payload = {
      updatedAt: Time.now.utc.iso8601,
      count: balloons.size,
      balloons: balloons,
      insights: { fastest: fastest, bestTail: bestTail }
    }

    if debug
      payload[:debug] = (fetch_meta || {}).merge(
        {
          tracks_total: tracks.size,
          enriched_count: enriched_map.size,
          subset_strategy: "top_by_drift_speed",
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
            bestTail: bestTail.length
          }
        }
      )
    end

    payload
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
